<?php
session_start();
require_once __DIR__ . '/config.php';
$loggedIn = isset($_SESSION['logged_in']) && $_SESSION['logged_in'] === true;
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_POST['action']) && $_POST['action'] === 'login') {
    $u = isset($_POST['username']) ? trim($_POST['username']) : '';
    $p = isset($_POST['password']) ? $_POST['password'] : '';
    if ($u === $ADMIN_USERNAME && $p === $ADMIN_PASSWORD) {
        $_SESSION['logged_in'] = true;
        $loggedIn = true;
    } else {
        $error = 'Invalid credentials';
    }
}
if (isset($_GET['action']) && $_GET['action'] === 'logout') {
    $_SESSION['logged_in'] = false;
    session_destroy();
    header('Location: /manager/index.php');
    exit;
}
$selectedUser = null;
if ($loggedIn && isset($_GET['user'])) {
    $user = preg_replace('/[^a-zA-Z0-9_-]/', '', $_GET['user']);
    if ($user !== '') {
        $selectedUser = $user;
    }
}
function getSystemUsers() {
    $users = [];
    $excluded = ['ubuntu','aswin','ambadi'];
    if (is_readable('/etc/passwd')) {
        $lines = file('/etc/passwd');
        foreach ($lines as $line) {
            $parts = explode(':', trim($line));
            if (count($parts) >= 6) {
                $username = $parts[0];
                $home = $parts[5];
                if (!in_array($username, $excluded, true) && (
                    strpos($home, '/home/') === 0 ||
                    $username === 'root' ||
                    file_exists('/var/spool/cron/crontabs/' . $username)
                )) {
                    $users[] = ['username' => $username, 'home' => $home];
                }
            }
        }
    }
    usort($users, function($a, $b) { return strcmp($a['username'], $b['username']); });
    return $users;
}
$users = $loggedIn ? getSystemUsers() : [];
?>
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Management Dashboard</title>
    <style>
        * { box-sizing: border-box; margin: 0; padding: 0; font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; }
        body { background-color: #f5f7fa; color: #333; }
        .container { max-width: 1200px; margin: 0 auto; padding: 20px; }
        header { background-color: #2c3e50; color: white; padding: 20px; border-radius: 8px; margin-bottom: 20px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
        h1 { font-size: 28px; margin-bottom: 15px; }
        .domain-container { display: flex; flex-wrap: wrap; gap: 15px; margin-bottom: 30px; justify-content: flex-start; }
        .domain-block { background-color: #3498db; color: white; padding: 15px; border-radius: 6px; width: calc(33.333% - 10px); height: 60px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); display: flex; align-items: center; transition: transform .2s, box-shadow .2s; }
        .domain-block:hover { transform: translateY(-3px); box-shadow: 0 4px 8px rgba(0,0,0,0.2); }
        .domain-icon { font-size: 24px; margin-right: 15px; }
        .domain-name { font-size: 16px; font-weight: 500; word-break: break-all; }
        .card-container { display: flex; flex-wrap: wrap; gap: 20px; margin-top: 20px; }
        .card { background-color: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 25px; flex: 1 0 calc(33.333% - 20px); min-width: 300px; transition: transform .2s, box-shadow .2s; }
        .card:hover { transform: translateY(-5px); box-shadow: 0 8px 15px rgba(0,0,0,0.1); }
        .card-icon { font-size: 32px; margin-bottom: 15px; }
        h2 { font-size: 22px; margin-bottom: 15px; color: #2c3e50; }
        p { color: #7f8c8d; margin-bottom: 20px; line-height: 1.5; }
        .button { display: inline-block; background-color: #3498db; color: white; padding: 10px 20px; border-radius: 4px; text-decoration: none; font-weight: 500; transition: background-color .2s; }
        .button:hover { background-color: #2980b9; }
        footer { text-align: center; margin-top: 40px; padding: 20px; color: #7f8c8d; font-size: 14px; }
        @media (max-width: 768px) { .domain-block { width: calc(50% - 8px); } .card { flex: 1 0 100%; } }
        @media (max-width: 480px) { .domain-block { width: 100%; } }
        .login { background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 25px; max-width: 420px; margin: 20px auto; }
        .form-row { margin-bottom: 15px; }
        .form-row label { display: block; margin-bottom: 6px; color: #2c3e50; }
        .form-row input { width: 100%; padding: 10px; border: 1px solid #d0d7de; border-radius: 6px; }
        .users { display: grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap: 12px; }
        .user { background: white; border: 1px solid #e1e8f0; border-radius: 8px; padding: 12px; cursor: pointer; display: flex; align-items: center; }
        .user:hover { border-color: #c9d6e3; box-shadow: 0 2px 6px rgba(0,0,0,0.06); }
        .user .avatar { width: 36px; height: 36px; border-radius: 50%; background: #3498db; color: white; display: inline-flex; align-items: center; justify-content: center; margin-right: 10px; font-weight: 600; }
        .panels { display: grid; grid-template-columns: repeat(3, 1fr); gap: 16px; margin-top: 20px; }
        .panel { background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 12px; }
        .panel h3 { margin-bottom: 10px; color: #2c3e50; }
        iframe { width: 100%; height: 600px; border: 0; border-radius: 6px; background: #f8f9fb; }
        .topbar { display: flex; justify-content: space-between; align-items: center; margin-top: 10px; }
        .logout { color: #fff; background: #e74c3c; padding: 8px 12px; border-radius: 6px; text-decoration: none; }
        .logout:hover { background: #c0392b; }
    </style>
    </head>
<body>
    <div class="container">
        <header>
            <div class="topbar">
                <h1>Server Management Dashboard</h1>
                <?php if ($loggedIn): ?>
                    <a class="logout" href="?action=logout">Logout</a>
                <?php endif; ?>
            </div>
            <div class="domain-container">
                <div class="domain-block"><div class="domain-icon">🌐</div><div class="domain-name">Manager</div></div>
            </div>
        </header>
        <?php if (!$loggedIn): ?>
            <div class="login">
                <form method="post">
                    <?php if (isset($error)): ?><div style="color:#e74c3c;margin-bottom:10px;"><?php echo htmlspecialchars($error); ?></div><?php endif; ?>
                    <input type="hidden" name="action" value="login" />
                    <div class="form-row"><label>Username</label><input name="username" type="text" required /></div>
                    <div class="form-row"><label>Password</label><input name="password" type="password" required /></div>
                    <button class="button" type="submit">Login</button>
                </form>
            </div>
        <?php else: ?>
            <?php if (!$selectedUser): ?>
                <h2 style="margin:10px 0 12px;">Users</h2>
                <div class="users">
                    <?php foreach ($users as $u): $name=$u['username']; ?>
                        <a class="user" href="?user=<?php echo urlencode($name); ?>">
                            <div class="avatar"><?php echo strtoupper(substr($name,0,1)); ?></div>
                            <div>
                                <div style="font-weight:600; color:#2c3e50;"><?php echo htmlspecialchars($name); ?></div>
                                <div style="font-size:12px; color:#7f8c8d; word-break:break-all;"><?php echo htmlspecialchars($u['home']); ?></div>
                            </div>
                        </a>
                    <?php endforeach; ?>
                </div>
            <?php else: ?>
                <h2 style="margin:10px 0 12px;">User: <?php echo htmlspecialchars($selectedUser); ?></h2>
                <div class="panels">
                    <div class="panel">
                        <h3>File Browser</h3>
                        <iframe src="/manager/files/"></iframe>
                    </div>
                    <div class="panel">
                        <h3>Database Manager</h3>
                        <iframe src="/manager/db/"></iframe>
                    </div>
                    <div class="panel">
                        <h3>Crontab Manager</h3>
                        <iframe src="/manager/crontab/edit/<?php echo urlencode($selectedUser); ?>"></iframe>
                    </div>
                </div>
            <?php endif; ?>
        <?php endif; ?>
    </div>
    <footer>
        <p>Server Management Dashboard &copy; 2025</p>
    </footer>
</body>
</html>