import os
import sys
import json
import django
import argparse
from pathlib import Path
from importlib import import_module
from tabulate import tabulate
from django.conf import settings
from django.apps import apps

try:
    import jinja2
except ImportError:
    jinja2 = None

# Globals
BASE_DIR = Path(__file__).resolve().parent
results = []

def report(category, item, value, warning=None):
    results.append({
        "category": category,
        "item": item,
        "value": value,
        "warning": warning
    })

def find_settings_module():
    for root, dirs, files in os.walk(BASE_DIR):
        if "settings.py" in files:
            rel_path = os.path.relpath(root, BASE_DIR)
            return ".".join(Path(rel_path).parts) + ".settings"
    return None

def setup_django():
    settings_module = os.environ.get("DJANGO_SETTINGS_MODULE") or find_settings_module()
    if not settings_module:
        print("Could not find Django settings module.")
        sys.exit(1)
    os.environ.setdefault("DJANGO_SETTINGS_MODULE", settings_module)
    try:
        django.setup()
    except Exception as e:
        print(f"Failed to set up Django: {e}")
        sys.exit(1)

def check_debug():
    report("General", "DEBUG", settings.DEBUG, "Should be False in production" if settings.DEBUG else None)

def check_allowed_hosts():
    val = settings.ALLOWED_HOSTS or []
    report("General", "ALLOWED_HOSTS", val, "Empty ALLOWED_HOSTS is dangerous")

def check_csrf_settings():
    enabled = 'django.middleware.csrf.CsrfViewMiddleware' in settings.MIDDLEWARE
    report("Middleware", "CSRF Middleware", enabled, "Missing CSRF middleware")
    secure = getattr(settings, 'CSRF_COOKIE_SECURE', False)
    report("Cookies", "CSRF_COOKIE_SECURE", secure, "Should be True in production")

def check_admin_url():
    try:
        url_file = BASE_DIR / settings.ROOT_URLCONF.replace('.', '/') + '.py'
        if url_file.exists():
            with open(url_file) as f:
                if "admin.site.urls" in f.read():
                    report("Admin", "Admin URL Exposed", True, "Consider changing /admin/ to something non-default")
    except Exception:
        report("Admin", "Admin URL Check", "Unknown", "Failed to analyze urls.py")

def check_secret_key():
    sk = settings.SECRET_KEY
    if "django-insecure" in sk:
        warn = "Insecure default secret key"
    elif len(sk) < 50:
        warn = "Secret key is too short"
    else:
        warn = None
    report("General", "SECRET_KEY", "[REDACTED]", warn)

def check_updates():
    report("System", "Outdated Packages", "Use: pip list --outdated", "Run manually")

def check_file_upload_security():
    media_root = getattr(settings, 'MEDIA_ROOT', None)
    warn = "MEDIA_ROOT not set" if not media_root else None
    report("Files", "MEDIA_ROOT", media_root or "None", warn)

def check_cors_settings():
    try:
        from corsheaders.conf import settings as cors
        val = getattr(cors, "CORS_ORIGIN_ALLOW_ALL", False)
        warn = "CORS_ORIGIN_ALLOW_ALL = True" if val else None
        report("CORS", "CORS_ORIGIN_ALLOW_ALL", val, warn)
        origins = getattr(cors, "CORS_ALLOWED_ORIGINS", [])
        report("CORS", "CORS_ALLOWED_ORIGINS", origins)
    except ImportError:
        report("CORS", "CORS Configuration", "Not Installed", "Consider installing if you need cross-origin access")

def check_security_headers():
    headers = {
        "SECURE_HSTS_SECONDS": ("Headers", "Should be > 0 for HTTPS"),
        "SECURE_CONTENT_TYPE_NOSNIFF": ("Headers", "Should be True"),
        "SECURE_BROWSER_XSS_FILTER": ("Headers", "Should be True"),
        "SESSION_COOKIE_SECURE": ("Cookies", "Should be True"),
        "CSRF_COOKIE_SECURE": ("Cookies", "Should be True"),
        "X_FRAME_OPTIONS": ("Headers", "Should be 'DENY' or 'SAMEORIGIN'"),
    }
    for key, (cat, advice) in headers.items():
        val = getattr(settings, key, None)
        warn = None if val else advice
        report(cat, key, val, warn)

def check_database():
    db = settings.DATABASES.get('default', {})
    engine = db.get("ENGINE", "")
    name = db.get("NAME", "")
    ssl = db.get("OPTIONS", {}).get("sslmode", "")
    warn = None
    if "sqlite" in engine and not settings.DEBUG:
        warn = "SQLite should not be used in production"
    if ssl in ["disable", None] and "postgres" in engine:
        warn = "SSL not enforced for DB connection"
    report("Database", "Engine", engine, warn)
    report("Database", "Name", name)

def check_middleware():
    dangerous = [
        "django.middleware.common.BrokenLinkEmailsMiddleware",
        "django.middleware.http.ConditionalGetMiddleware",
        "django.middleware.clickjacking.XFrameOptionsMiddleware",
        "django.middleware.gzip.GZipMiddleware",
    ]
    for mw in settings.MIDDLEWARE:
        if mw in dangerous:
            report("Middleware", mw, "Present", "Review if necessary")
    if "django.middleware.security.SecurityMiddleware" not in settings.MIDDLEWARE:
        report("Middleware", "SecurityMiddleware", "Missing", "Highly recommended")

def check_installed_apps():
    unused = []
    for app in settings.INSTALLED_APPS:
        try:
            apps.get_app_config(app.split('.')[-1])
        except LookupError:
            unused.append(app)
    if unused:
        for app in unused:
            report("Apps", app, "Possibly Unused", "App in INSTALLED_APPS but not detected as loaded")

# ---------- Output Options ----------

def render_table():
    headers = ["Category", "Item", "Value", "Warning"]
    rows = [[r["category"], r["item"], str(r["value"]), r["warning"] or ""] for r in results]
    print(tabulate(rows, headers=headers, tablefmt="fancy_grid"))

def render_json():
    print(json.dumps(results, indent=2))

def render_html():
    if not jinja2:
        print("Jinja2 not installed. Install with: pip install jinja2")
        return
    template = jinja2.Template("""
    <html><head><title>Django Security Audit</title><style>
    body { font-family: sans-serif; padding: 20px; }
    table { border-collapse: collapse; width: 100%; }
    th, td { border: 1px solid #ccc; padding: 8px; }
    th { background-color: #f4f4f4; }
    .warn { color: red; font-weight: bold; }
    </style></head><body>
    <h1>Django Security Audit</h1>
    <table>
        <thead><tr><th>Category</th><th>Item</th><th>Value</th><th>Warning</th></tr></thead>
        <tbody>
        {% for row in results %}
        <tr>
            <td>{{ row.category }}</td>
            <td>{{ row.item }}</td>
            <td>{{ row.value }}</td>
            <td class="warn">{{ row.warning or "" }}</td>
        </tr>
        {% endfor %}
        </tbody>
    </table>
    </body></html>
    """)
    html = template.render(results=results)
    with open("security_audit_report.html", "w") as f:
        f.write(html)
    print("HTML report saved as security_audit_report.html")

# ---------- Main ----------

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', action='store_true', help='Output as JSON')
    parser.add_argument('--html', action='store_true', help='Output as HTML (requires jinja2)')
    args = parser.parse_args()

    setup_django()

    # Run checks
    check_debug()
    check_allowed_hosts()
    check_csrf_settings()
    check_admin_url()
    check_secret_key()
    check_updates()
    check_file_upload_security()
    check_cors_settings()
    check_security_headers()
    check_database()
    check_middleware()
    check_installed_apps()

    # Output results
    if args.json:
        render_json()
    elif args.html:
        render_html()
    else:
        render_table()

if __name__ == "__main__":
    main()
