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
        .button { display: inline-block; background-color: #3498db; color: white; padding: 10px 16px; border-radius: 6px; text-decoration: none; font-weight: 500; transition: background-color .2s; }
        .button:hover { background-color: #2980b9; }
        .login { background: white; border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,0.1); padding: 25px; max-width: 420px; margin: 40px auto; }
        .form-row { margin-bottom: 15px; }
        .form-row label { display: block; margin-bottom: 6px; color: #2c3e50; }
        .form-row input { width: 100%; padding: 10px; border: 1px solid #d0d7de; border-radius: 6px; }
        .layout { display: grid; grid-template-columns: 240px 1fr; min-height: 100vh; }
        .sidebar { background: #1f2a44; color: #fff; padding: 20px; }
        .brand { font-size: 18px; font-weight: 600; margin-bottom: 20px; }
        .nav { display: grid; gap: 8px; }
        .nav a { color: #c9d6e3; text-decoration: none; padding: 10px 12px; border-radius: 6px; display: block; }
        .nav a.active, .nav a:hover { background: #2b3b5f; color: #fff; }
        .content { padding: 24px; }
        .topbar { display: flex; justify-content: space-between; align-items: center; margin-bottom: 16px; }
        .title { font-size: 22px; font-weight: 600; color: #2c3e50; }
        .search { width: 340px; max-width: 60vw; padding: 10px; border: 1px solid #d0d7de; border-radius: 8px; }
        .logout { color: #fff; background: #e74c3c; padding: 8px 12px; border-radius: 6px; text-decoration: none; }
        .logout:hover { background: #c0392b; }
        .table { width: 100%; border-collapse: collapse; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 10px rgba(0,0,0,0.06); }
        .table th, .table td { padding: 12px 14px; border-bottom: 1px solid #eef2f6; text-align: left; }
        .table th { background: #f7fafc; color: #2c3e50; font-weight: 600; }
        .row-actions { display: flex; gap: 8px; }
        .badge { display: inline-block; background: #eef4fb; color: #1f4f8c; padding: 4px 8px; border-radius: 6px; font-size: 12px; }
        @media (max-width: 900px) { .layout { grid-template-columns: 1fr; } .sidebar { display:none; } .search { width: 100%; } }
    </style>
    </head>
<body>
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
                <div class="layout">
                    <aside class="sidebar">
                        <div class="brand">Manager</div>
                        <div class="nav">
                            <a class="active" href="#">Tools</a>
                        </div>
                    </aside>
                    <main class="content">
                        <div class="topbar">
                            <div class="title">Tools</div>
                            <div>
                                <input id="search" class="search" type="text" placeholder="Search users or domains" oninput="filterRows()" />
                                <a class="logout" href="?action=logout" style="margin-left:10px;">Logout</a>
                            </div>
                        </div>
                        <table class="table" id="usersTable">
                            <thead>
                                <tr>
                                    <th>User</th>
                                    <th>Home Directory</th>
                                    <th>Actions</th>
                                </tr>
                            </thead>
                            <tbody>
                                <?php foreach ($users as $u): $name=$u['username']; ?>
                                <tr data-username="<?php echo htmlspecialchars($name); ?>" data-home="<?php echo htmlspecialchars($u['home']); ?>">
                                    <td>
                                        <a href="?user=<?php echo urlencode($name); ?>" target="_blank" style="text-decoration:none; color:#2c3e50; font-weight:600;">
                                            <?php echo htmlspecialchars($name); ?>
                                        </a>
                                    </td>
                                    <td><span class="badge"><?php echo htmlspecialchars($u['home']); ?></span></td>
                                    <td>
                                        <div class="row-actions">
                                            <a class="button" href="/manager/files/" target="_blank">File Manager</a>
                                            <a class="button" href="/manager/db/" target="_blank">Databases</a>
                                            <a class="button" href="/manager/crontab/edit/<?php echo urlencode($name); ?>" target="_blank">Crontab</a>
                                        </div>
                                    </td>
                                </tr>
                                <?php endforeach; ?>
                            </tbody>
                        </table>
                        <script>
                        function filterRows(){
                            var q=document.getElementById('search').value.toLowerCase();
                            var rows=document.querySelectorAll('#usersTable tbody tr');
                            rows.forEach(function(r){
                                var u=r.getAttribute('data-username').toLowerCase();
                                var h=r.getAttribute('data-home').toLowerCase();
                                r.style.display = (u.indexOf(q)>-1 || h.indexOf(q)>-1)?'':'none';
                            });
                        }
                        </script>
                    </main>
                </div>
            <?php else: ?>
                <h2 style="margin:10px 0 12px;">User: <?php echo htmlspecialchars($selectedUser); ?></h2>
                <div style="display:flex;flex-direction:column;gap:16px;margin-top:12px;">
                    <div class="panel" style="padding:20px;">
                        <h3 style="margin-bottom:12px;">File Manager</h3>
                        <a class="button" href="/manager/files/" target="_blank">Open File Browser</a>
                    </div>
                    <div class="panel" style="padding:20px;">
                        <h3 style="margin-bottom:12px;">Databases</h3>
                        <a class="button" href="/manager/db/" target="_blank">Open phpMyAdmin</a>
                    </div>
                    <div class="panel" style="padding:20px;">
                        <h3 style="margin-bottom:12px;">Crontab</h3>
                        <a class="button" href="/manager/crontab/edit/<?php echo urlencode($selectedUser); ?>" target="_blank">Open Crontab Editor</a>
                    </div>
                </div>
            <?php endif; ?>
        <?php endif; ?>
    </body>
    </html>