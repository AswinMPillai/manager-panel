from flask import Flask, render_template, request, redirect, url_for, session, flash
import subprocess
import os
import re
import tempfile
import pwd
import json
from functools import wraps
import secrets
from werkzeug.middleware.proxy_fix import ProxyFix
import logging
from flask_caching import Cache

# Configure logging
logging.basicConfig(level=logging.DEBUG)

# Create Flask application
def create_app():
    app = Flask(__name__)
    app.secret_key = secrets.token_hex(16)  # Generate a secure secret key

    # Fix for running behind a reverse proxy
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1, x_prefix=1)

    # Configuration
    app.config['ADMIN_USERNAME'] = 'admin'
    app.config['ADMIN_PASSWORD'] = 'Emergio@2025'  # Change this in production
    app.config['DESCRIPTIONS_FILE'] = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'user_descriptions.json')

    app.config['CACHE_TYPE'] = 'redis'
    app.config['CACHE_REDIS_HOST'] = 'localhost'
    app.config['CACHE_REDIS_PORT'] = 6379
    app.config['CACHE_DEFAULT_TIMEOUT'] = 600  # Cache expires in 10 minutes

    # Middleware to handle proxy path
    class PrefixMiddleware:
        def __init__(self, app):
            self.app = app

        def __call__(self, environ, start_response):
            script_name = environ.get('HTTP_X_SCRIPT_NAME', '')
            if script_name:
                environ['SCRIPT_NAME'] = script_name
                path_info = environ['PATH_INFO']
                if path_info.startswith(script_name):
                    environ['PATH_INFO'] = path_info[len(script_name):]

            # Debug logging to help troubleshoot
            app.logger.debug(f"SCRIPT_NAME: {environ.get('SCRIPT_NAME')}, PATH_INFO: {environ.get('PATH_INFO')}")

            return self.app(environ, start_response)

    app.wsgi_app = PrefixMiddleware(app.wsgi_app)

    return app

app = create_app()
cache = Cache(app)

# Authentication decorator
def login_required(f):
    @wraps(f)
    def decorated_function(*args, **kwargs):
        logged_in = cache.get('logged_in')
        header_user = request.headers.get('X-Authenticated-User', '')
        if header_user:
            cache.set('logged_in', True, timeout=3600)
            logged_in = True
        if not logged_in:
            return redirect(url_for('login'))
        return f(*args, **kwargs)
    return decorated_function

def get_system_users():
    """Get all system users with /home directory and root"""
    users = []
    excluded_users = ['ubuntu', 'aswin', 'ambadi']
    try:
        app.logger.debug("Getting system users")
        for user in pwd.getpwall():
            # Include users with home directories or system users that might have crontabs
            if user.pw_name not in excluded_users and (
                user.pw_dir.startswith('/home/') or
                user.pw_name in ['root'] or
                os.path.exists(f"/var/spool/cron/crontabs/{user.pw_name}")):
                users.append({
                    'username': user.pw_name,
                    'home_dir': user.pw_dir,
                    'description': get_user_description(user.pw_name)
                })
    except Exception as e:
        app.logger.error(f"Error getting system users: {str(e)}")
    app.logger.debug(f"Found {len(users)} users")
    return sorted(users, key=lambda x: x['username'])

def get_user_description(username):
    """Get user description from the JSON file"""
    try:
        if os.path.exists(app.config['DESCRIPTIONS_FILE']):
            with open(app.config['DESCRIPTIONS_FILE'], 'r') as f:
                descriptions = json.load(f)
                return descriptions.get(username, '')
    except Exception as e:
        return ''

def save_user_description(username, description):
    """Save user description to the JSON file"""
    try:
        descriptions = {}
        if os.path.exists(app.config['DESCRIPTIONS_FILE']):
            try:
                with open(app.config['DESCRIPTIONS_FILE'], 'r') as f:
                    descriptions = json.load(f)
            except json.JSONDecodeError:
                # If the file exists but is not valid JSON, start with an empty dict
                pass

        descriptions[username] = description

        # Ensure directory exists
        os.makedirs(os.path.dirname(app.config['DESCRIPTIONS_FILE']), exist_ok=True)

        with open(app.config['DESCRIPTIONS_FILE'], 'w') as f:
            json.dump(descriptions, f)
    except Exception as e:
        app.logger.error(f"Error saving user description: {str(e)}")

def parse_cron_expression(expression):
    """Parse a crontab expression into components"""
    parts = expression.strip().split()
    if len(parts) < 5:  # Need at least 5 parts for cron timing
        return None

    return {
        'minute': parts[0],
        'hour': parts[1],
        'day': parts[2],
        'month': parts[3],
        'weekday': parts[4],
        'command': ' '.join(parts[5:])
    }

def build_cron_expression(minute, hour, day, month, weekday, command):
    """Build a crontab expression from components"""
    return f"{minute} {hour} {day} {month} {weekday} {command}"

def get_cron_jobs(username):
    """Get all cron jobs for a user"""
    jobs = []
    try:
        app.logger.debug(f"Getting cron jobs for user: {username}")
        # First, check if user has a crontab
        check_result = subprocess.run(
            ['sudo', 'crontab', '-u', username, '-l'],
            capture_output=True, text=True
        )

        app.logger.debug(f"Crontab command return code: {check_result.returncode}")
        app.logger.debug(f"Crontab command output: {check_result.stdout[:100]}...")  # Log first 100 chars

        if check_result.returncode == 0:
            for line in check_result.stdout.splitlines():
                line = line.strip()
                if line and not line.startswith('#'):
                    job = parse_cron_expression(line)
                    if job:
                        jobs.append(job)

        app.logger.debug(f"Found {len(jobs)} cron jobs for {username}")
    except Exception as e:
        app.logger.error(f"Error getting cron jobs for {username}: {str(e)}")
    return jobs

def validate_crontab(content):
    """Enhanced validation of crontab syntax"""
    for line in content.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue

        # Check for environment variable settings (KEY=VALUE)
        if '=' in line and not line.startswith('@'):
            key = line.split('=')[0].strip()
            if key and key.isalnum():  # Simple check for valid env var names
                continue
            return False

        # Check for special time strings
        if line.startswith('@'):
            parts = re.split(r'\s+', line, 1)
            if len(parts) < 2 or parts[0] not in ['@reboot', '@yearly', '@annually', '@monthly', '@weekly', '@daily', '@hourly']:
                return False
            continue

        # Standard cron expression validation
        parts = re.split(r'\s+', line, 5)
        if len(parts) < 6:
            return False

    return True

@app.route('/')
def root():
    """Redirect root to index or login"""
    logged_in = cache.get('logged_in')
    if logged_in:
        return redirect(url_for('index'))
    return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    app.logger.debug(f"Login route called with method: {request.method}")
    if request.method == 'POST':
        username = request.form.get('username', '')
        password = request.form.get('password', '')

        app.logger.debug(f"Login attempt with username: {username}")

        if username == app.config['ADMIN_USERNAME'] and password == app.config['ADMIN_PASSWORD']:
            cache.set('logged_in', True, timeout=3600)
            flash('Login successful')
            return redirect(url_for('index'))
        else:
            flash('Invalid credentials')
    return render_template('login.html')

@app.route('/logout')
def logout():
    cache.delete('logged_in')
    flash('Logged out successfully')
    return redirect(url_for('login'))

@app.route('/index')
@login_required
def index():
    app.logger.debug("Index route called")
    users = get_system_users()
    return render_template('index.html', users=users)

@app.route('/edit_description/<username>', methods=['POST'])
@login_required
def edit_description(username):
    description = request.form.get('description', '')
    save_user_description(username, description)
    flash(f"Description for {username} updated successfully")
    return redirect(url_for('index'))

@app.route('/edit/<username>', methods=['GET', 'POST'])
@login_required
def edit_crontab(username):
    app.logger.debug(f"Edit crontab route called for user: {username} with method: {request.method}")

    if request.method == 'POST':
        # Check if this is a direct edit or using the form builder
        if 'crontab_content' in request.form:
            # Direct edit of the crontab
            crontab_content = request.form['crontab_content'].replace('\r\n', '\n').replace('\r', '\n')

            # Validate crontab content
            if not validate_crontab(crontab_content):
                flash("Invalid crontab syntax. Please check your entries.")
                return render_template('edit.html', username=username, crontab_content=crontab_content)

            # Write to temporary file with proper line endings
            with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp:
                temp_path = temp.name
                temp.write(crontab_content)
        else:
            # Get form data
            minute = request.form.get('minute', '*')
            hour = request.form.get('hour', '*')
            day = request.form.get('day', '*')
            month = request.form.get('month', '*')
            weekday = request.form.get('weekday', '*')
            command = request.form.get('command', '').strip()
            edit_mode = request.form.get('edit_mode', 'add')

            if not command:
                flash("Command cannot be empty")
                return redirect(url_for('edit_crontab', username=username))

            # Get current crontab content
            try:
                result = subprocess.run(['sudo', 'crontab', '-u', username, '-l'],
                                      capture_output=True, text=True)
                if result.returncode == 0:
                    crontab_content = result.stdout
                else:
                    crontab_content = ""
            except Exception as e:
                app.logger.error(f"Error getting crontab: {str(e)}")
                crontab_content = ""

            # Check if we're editing an existing job
            if edit_mode == 'edit':
                # Get original values
                original_minute = request.form.get('original_minute', '')
                original_hour = request.form.get('original_hour', '')
                original_day = request.form.get('original_day', '')
                original_month = request.form.get('original_month', '')
                original_weekday = request.form.get('original_weekday', '')
                original_command = request.form.get('original_command', '')

                # Build the original job string
                original_job = build_cron_expression(
                    original_minute, original_hour, original_day,
                    original_month, original_weekday, original_command)

                # Replace the original job with the new one
                new_job = build_cron_expression(minute, hour, day, month, weekday, command)

                # Create a new crontab content with the replaced job
                new_crontab_lines = []
                for line in crontab_content.splitlines():
                    if line.strip() == original_job.strip():
                        new_crontab_lines.append(new_job)
                    else:
                        new_crontab_lines.append(line)

                crontab_content = '\n'.join(new_crontab_lines)
                if crontab_content and not crontab_content.endswith('\n'):
                    crontab_content += '\n'
            else:
                # We're adding a new job
                new_job = build_cron_expression(minute, hour, day, month, weekday, command)
                if crontab_content and not crontab_content.endswith('\n'):
                    crontab_content += '\n'
                crontab_content += new_job + '\n'

            # Write to temporary file
            with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp:
                temp_path = temp.name
                temp.write(crontab_content)

        try:
            # Make the temp file readable by all users
            os.chmod(temp_path, 0o644)

            # Update the crontab using a more reliable approach
            app.logger.debug(f"Updating crontab with temp file: {temp_path}")
            result = subprocess.run(['sudo', 'crontab', '-u', username, temp_path],
                                  capture_output=True, text=True, check=True)

            if 'edit_mode' in request.form and request.form['edit_mode'] == 'edit':
                flash(f"Cron job updated successfully")
            else:
                flash(f"Crontab for {username} updated successfully")

            # Verify the crontab was actually installed
            verify = subprocess.run(['sudo', 'crontab', '-u', username, '-l'],
                                   capture_output=True, text=True)
            app.logger.debug(f"Verification result: {verify.returncode}, Output: {verify.stdout[:100]}...")

            if verify.returncode != 0 or not verify.stdout.strip():
                flash("Warning: Crontab may not have been properly installed. Please check.")

            os.unlink(temp_path)
            return redirect(url_for('edit_crontab', username=username))
        except subprocess.CalledProcessError as e:
            flash(f"Error updating crontab: {e.stderr}")
            app.logger.error(f"Crontab update error: {e.stderr}")
            os.unlink(temp_path)
            return redirect(url_for('edit_crontab', username=username))

    try:
        app.logger.debug(f"Getting current crontab for user: {username}")
        result = subprocess.run(['sudo', 'crontab', '-u', username, '-l'],
                              capture_output=True, text=True)
        app.logger.debug(f"Crontab fetch result: {result.returncode}")

        if result.returncode == 0:
            crontab_content = result.stdout
            app.logger.debug(f"Got crontab content length: {len(crontab_content)}")
        else:
            crontab_content = "# No crontab for " + username
            app.logger.debug(f"No crontab found for user: {username}")
    except Exception as e:
        app.logger.error(f"Error retrieving crontab: {str(e)}")
        crontab_content = f"# Error retrieving crontab: {str(e)}"

    user_description = get_user_description(username)
    cron_jobs = get_cron_jobs(username)
    app.logger.debug(f"Rendering edit template with {len(cron_jobs)} jobs")

    return render_template('edit.html', username=username, crontab_content=crontab_content,
                         user_description=user_description, cron_jobs=cron_jobs)

@app.route('/delete_cron/<username>', methods=['POST'])
@login_required
def delete_cron(username):
    minute = request.form.get('minute', '*')
    hour = request.form.get('hour', '*')
    day = request.form.get('day', '*')
    month = request.form.get('month', '*')
    weekday = request.form.get('weekday', '*')
    command = request.form.get('command', '').strip()

    # Create the job string to remove
    job_to_remove = build_cron_expression(minute, hour, day, month, weekday, command)

    # Get current crontab content
    try:
        result = subprocess.run(['sudo', 'crontab', '-u', username, '-l'],
                              capture_output=True, text=True)
        if result.returncode == 0:
            crontab_content = result.stdout
        else:
            flash("Error: Could not retrieve current crontab")
            return redirect(url_for('edit_crontab', username=username))
    except Exception as e:
        flash(f"Error: {str(e)}")
        return redirect(url_for('edit_crontab', username=username))

    # Remove the job
    new_crontab = []
    for line in crontab_content.splitlines():
        if line.strip() != job_to_remove.strip():
            new_crontab.append(line)

    new_crontab_content = '\n'.join(new_crontab)
    if new_crontab_content and not new_crontab_content.endswith('\n'):
        new_crontab_content += '\n'

    # Write to temporary file
    with tempfile.NamedTemporaryFile(mode='w', delete=False) as temp:
        temp_path = temp.name
        temp.write(new_crontab_content)

    try:
        # Make the temp file readable by all users
        os.chmod(temp_path, 0o644)

        # Update the crontab
        result = subprocess.run(['sudo', 'crontab', '-u', username, temp_path],
                              capture_output=True, text=True, check=True)

        flash(f"Cron job deleted successfully")
        os.unlink(temp_path)
    except subprocess.CalledProcessError as e:
        flash(f"Error deleting cron job: {e.stderr}")
        os.unlink(temp_path)

    return redirect(url_for('edit_crontab', username=username))

# Only run the app directly when executed as a script
if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8765, debug=False)
