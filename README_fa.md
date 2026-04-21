# MRVPN Manager Panel

یک پنل مدیریت سبک برای نصب، مدیریت و مانیتورینگ سرورهای [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN).

---

> 🌐 [English README](README.md)

---

## قابلیت‌ها

- **احراز هویت JWT** — بدون session، کاملاً stateless
- **نصب‌کننده نسخه‌آگاه** — انتخاب بین build های ۵ آوریل و ۱۲ آوریل
- **تزریق خودکار دامنه** — config آماده با دامنه شما
- **داشبورد تحت وب** — آمار real-time پردازنده، RAM، دیسک و شبکه از طریق WebSocket
- **ویرایشگر config در مرورگر** — مشاهده و ویرایش `server_config.toml` و `encrypt_key.txt` مستقیم از داشبورد، با ری‌استارت خودکار سرویس پس از ذخیره
- **زمان‌بندی config** — تعریف چند config برای ساعات مختلف روز و جابجایی خودکار توسط سرویس سیستم
- **نصب مجدد و تغییر نسخه با یک دستور** — با امکان نگه‌داشتن key و config قبلی
- **حذف کامل با یک دستور** — پاک‌سازی تمام سرویس‌ها، فایل‌ها و تغییرات سیستمی
- **مدیریت شده توسط systemd** — پنل، VPN و زمان‌بند همه به عنوان سرویس اجرا می‌شوند و پس از crash یا ریبوت مجدداً راه‌اندازی می‌شوند

---

## نصب (Installation)

```bash
curl -fsSL https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/install.sh -o install.sh
sudo bash install.sh
```

نصب‌کننده از شما می‌پرسد:

1. آیا می‌خواهید **پنل** را نصب/آپدیت کنید؟
   - سوال: `Install/update Panel? (y/n):`
2. آیا می‌خواهید **MasterDnsVPN** را نصب/آپدیت کنید؟
   - سوال: `Install/update MasterDnsVPN? (y/n):`
   - کدام نسخه: `1) April 5` یا `2) April 12`
   - دامنه شما (مثال: `vpn.example.com`)
   - آیا `server_config.toml` و `encrypt_key.txt` موجود نگه داشته شوند؟
     - سوال: `Back up existing server_config.toml? (y/n):`

فایل‌های MasterDnsVPN (شامل `server_config.toml`، `encrypt_key.txt` و باینری) در مسیر `/root` نصب می‌شوند که با رفتار نصب‌کننده رسمی مطابقت دارد.

---

## حذف (Uninstallation)

در هنگام اجرای نصب‌کننده گزینه **۲** را انتخاب کنید، یا مستقیماً حذف‌کننده را اجرا کنید:

```bash
curl -fsSL https://raw.githubusercontent.com/sam-soofy/mrvpn-manager-panel/main/uninstall.sh -o uninstall.sh
sudo bash uninstall.sh
```

حذف‌کننده تأیید نهایی می‌خواهد:
- سوال: `Type 'yes' to confirm full uninstall:`

حذف‌کننده این موارد را انجام می‌دهد:
- توقف و حذف هر سه سرویس systemd
- حذف `/opt/mrvpn-manager-panel` (فایل‌های پنل)
- حذف باینری MasterDnsVPN و دقیقاً `server_config.toml` و `encrypt_key.txt` از `/root` — فایل‌های backup کاربر (با پسوند `.backup`، `.bak` و غیره) دست نخورده می‌مانند
- بررسی فایل‌های باقی‌مانده از نصب‌های قدیمی (مثلاً `/opt/masterdnsvpn`)
- بازگرداندن تنظیم `DNSStubListener` در `/etc/systemd/resolved.conf`
- توصیه ریبوت برای اعمال کامل تغییرات شبکه

---

## اولین ورود (First Login)

پس از نصب، اطلاعات ورود در یک کادر واضح نمایش داده می‌شود:

```
╔══════════════════════════════════════════════════════╗
║          ★  SAVE YOUR LOGIN CREDENTIALS  ★          ║
╠══════════════════════════════════════════════════════╣
║                                                      ║
║  URL  : http://YOUR_SERVER_IP:5000                   ║
║  User : admin                                        ║
║  Pass : xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx             ║
║                                                      ║
╠══════════════════════════════════════════════════════╣
║  Password file: /opt/mrvpn-manager-panel/admin_pass.txt
║                                                      ║
║  TO RESET PASSWORD:                                  ║
║    nano /opt/mrvpn-manager-panel/admin_pass.txt      ║
║    systemctl restart mrvpn-manager-panel             ║
╚══════════════════════════════════════════════════════╝
```

این اطلاعات را در جای امنی ذخیره کنید.

---

## تغییر رمز عبور (Resetting Your Password)

پنل رمز را مستقیماً از فایل هنگام راه‌اندازی می‌خواند. برای تغییر:

```bash
# ۱. فایل رمز را ویرایش کنید (رمز جدید را جایگزین کنید)
nano /opt/mrvpn-manager-panel/admin_pass.txt

# ۲. پنل را ری‌استارت کنید تا تغییر اعمال شود
systemctl restart mrvpn-manager-panel
```

همین. بدون token اضافی، بدون script، بدون مراحل پیچیده.

---

## ویرایشگر Config (Config Editor)

روی **Edit server_config.toml** یا **Edit encrypt_key.txt** در داشبورد کلیک کنید تا یک ویرایشگر تمام‌صفحه باز شود. تغییرات روی دیسک ذخیره شده و MasterDnsVPN پس از تأیید شما به‌طور خودکار ری‌استارت می‌شود.

---

## زمان‌بند Config (Config Scheduler)

زمان‌بند به شما اجازه می‌دهد چند config سرور را برای ساعات مختلف روز تعریف کنید. مثلاً تنظیمات تهاجمی ARQ برای شب و تنظیمات سبک‌تر در ساعات پرترافیک.

### راه‌اندازی زمان‌بندی (Setting up a schedule)

1. داشبورد → بخش **Config Scheduler** → دکمه **Add Schedule**
2. نام، زمان (فرمت ۲۴ ساعته) و روزهای هفته را تنظیم کنید
3. محتوای TOML خود را paste کنید — یا روی **Load current config** کلیک کنید تا از config فعلی شروع کنید و آن را تغییر دهید
4. ذخیره کنید — برای بازه‌های زمانی دیگر تکرار کنید

### نحوه عملکرد (How it works)

یک سرویس systemd مجزا به نام `mrvpn-config-scheduler` هر ۳۰ ثانیه یکبار بررسی می‌کند. وقتی `HH:MM` فعلی با یک زمان‌بندی برای امروز مطابقت داشت، TOML ذخیره‌شده را در `/root/server_config.toml` می‌نویسد و سرویس VPN را ری‌استارت می‌کند. یک زمان‌بندی در یک دقیقه بیش از یک بار اجرا نمی‌شود.

> **توجه:** اگر دو زمان‌بندی یک زمان مشترک داشته باشند، فقط اولی در لیست اجرا می‌شود.

### از طریق API

```bash
# افزودن زمان‌بندی — Add a schedule
curl -X POST http://localhost:5000/api/schedules \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Night Mode",
    "time": "22:00",
    "days": ["mon","tue","wed","thu","fri","sat","sun"],
    "config": "... full TOML content ..."
  }'

# نمایش زمان‌بندی‌ها — List schedules
curl http://localhost:5000/api/schedules \
  -H "Authorization: Bearer <token>"

# حذف زمان‌بندی — Delete a schedule
curl -X DELETE http://localhost:5000/api/schedules/<id> \
  -H "Authorization: Bearer <token>"
```

---

## نحوه کلی عملکرد (How It Works)

```
install.sh   →  همه چیز را راه‌اندازی می‌کند: نصب، آپدیت، تغییر نسخه، حذف
systemd      →  پنل، VPN و زمان‌بند را پس از ریبوت و crash زنده نگه می‌دارد
web UI       →  مانیتورینگ سلامت سرور، ویرایش config، مدیریت زمان‌بندی‌ها
scheduler    →  config های زمان‌بندی‌شده را حتی وقتی داشبورد باز نیست اعمال می‌کند
```

| فایل | نقش |
|------|------|
| `install.sh` | نصب‌کننده، مدیر نسخه، ابزار آپدیت و راه‌اندازی حذف |
| `uninstall.sh` | حذف‌کننده مستقل — همه چیز را پاکیزه حذف می‌کند |
| `mrvpn_manager_panel.py` | اپلیکیشن اصلی Flask + SocketIO |
| `scheduler.py` | daemon سیستمی که config های زمان‌بندی‌شده را اعمال می‌کند |
| `auth.py` | ایجاد و تأیید توکن JWT |
| `config_editor.py` | خواندن/نوشتن config و فایل key در MasterDnsVPN |
| `service_manager.py` | ری‌استارت MasterDnsVPN از طریق systemd |
| `april5_server_config.toml` | config بهینه برای build پنجم آوریل |
| `april12_server_config.toml` | config بهینه برای build دوازدهم آوریل |

---

## رفتارهای هوشمند نصب‌کننده (Installer Smart Behaviours)

- **نصب MasterDnsVPN در `/root`** — مطابق با نصب‌کننده رسمی؛ باینری فایل‌های config را در همان دایرکتوری جستجو می‌کند
- **تشخیص نصب‌های موجود** — در دایرکتوری جاری و `WorkingDirectory` سرویس قبلی (نصب‌های قدیمی `/opt/masterdnsvpn` را هم پوشش می‌دهد)
- **بکاپ فایل‌ها** — قبل از هر تغییری می‌پرسد — به ازای هر فایل جداگانه
  - سوال: `Back up existing server_config.toml? (y/n):`
  - سوال: `Back up existing encrypt_key.txt? (y/n):`
- **تولید key قبل از بازگرداندن config** — جلوگیری از overwrite شدن config توسط باینری April 5 در اولین اجرا
- **آزادسازی port 53** — غیرفعال کردن خودکار stub listener سرویس `systemd-resolved` در صورت نیاز
- **سرویس systemd نسخه‌دار** — دستور `systemctl status masterdnsvpn` نشان می‌دهد کدام build در حال اجراست
- **نصب مجدد / تغییر نسخه** — در هر زمان می‌توانید `install.sh` را دوباره اجرا کنید

---

## مدیریت سرویس‌ها (Service Management)

### پنل (Panel)

```bash
systemctl status  mrvpn-manager-panel
systemctl restart mrvpn-manager-panel
journalctl -u mrvpn-manager-panel -f
```

### زمان‌بند Config (Config Scheduler)

```bash
systemctl status  mrvpn-config-scheduler
systemctl restart mrvpn-config-scheduler
journalctl -u mrvpn-config-scheduler -f
```

### MasterDnsVPN

```bash
systemctl status  masterdnsvpn
systemctl restart masterdnsvpn
journalctl -u masterdnsvpn -f
```

---

## API

### احراز هویت (Auth)

```
POST /api/auth/login
Body: { "username": "admin", "password": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }

POST /api/auth/refresh
Body: { "refresh_token": "..." }
Returns: { "ok": true, "access_token": "...", "refresh_token": "..." }
```

تمام endpoint های دیگر نیاز به `Authorization: Bearer <access_token>` دارند.

### کنترل VPN (VPN Control)

```
POST /api/restart          — ری‌استارت سرویس MasterDnsVPN
GET  /api/status           — وضعیت لحظه‌ای (CPU، RAM، دیسک، شبکه)
```

### Config

```
GET  /api/config/server    — خواندن server_config.toml
POST /api/config/server    — نوشتن server_config.toml و ری‌استارت VPN
GET  /api/config/key       — خواندن encrypt_key.txt
POST /api/config/key       — نوشتن encrypt_key.txt و ری‌استارت VPN
```

تمام عملیات نوشتن نیاز به `"confirmed": true` در body دارند. اولین فراخوانی بدون آن یک پیام تأییدیه برمی‌گرداند.

### زمان‌بند (Scheduler)

```
GET    /api/schedules           — نمایش همه زمان‌بندی‌ها (بدون محتوای config)
POST   /api/schedules           — ایجاد زمان‌بندی
GET    /api/schedules/<id>      — دریافت یک زمان‌بندی با محتوای کامل config
PUT    /api/schedules/<id>      — آپدیت زمان‌بندی
DELETE /api/schedules/<id>      — حذف زمان‌بندی
```

---

## صفحات رابط کاربری (UI Pages)

| مسیر (Route) | توضیح |
|-------|-------------|
| `/` | داشبورد — آمار real-time، ویرایشگر config، زمان‌بند |
| `/login` | صفحه ورود |
| `/api/status` | JSON وضعیت سرور |

---

## عیب‌یابی (Debugging)

**پنل راه‌اندازی نمی‌شود (Panel not starting)**
```bash
journalctl -u mrvpn-manager-panel -n 50 --no-pager
```

**زمان‌بند config اعمال نمی‌شود (Scheduler not applying configs)**
```bash
journalctl -u mrvpn-config-scheduler -f
```

**port 53 در حال استفاده است (Port 53 already in use)**
```bash
ss -ulnp | grep :53
```
نصب‌کننده این را به‌طور خودکار مدیریت می‌کند. اگر مشکل ادامه داشت، سایر daemon های DNS را بررسی کنید (`named`، `dnsmasq`).

**VPN پس از ریبوت راه‌اندازی نمی‌شود (VPN not starting after reboot)**
```bash
systemctl is-enabled masterdnsvpn
systemctl enable masterdnsvpn   # اگر فعال نبود
```

**پکیج‌های Python وجود ندارند (Missing Python packages)**
```bash
cd /opt/mrvpn-manager-panel
.venv/bin/pip install -r requirements.txt
```

---

## پیش‌نیازها (Requirements)

- Ubuntu / Debian-based Linux
- دسترسی root
- Python 3.8+
- port 5000 باز باشد (پنل)
- port 53 UDP باز باشد (MasterDnsVPN)

---

## وابستگی‌ها (Dependencies)

```
flask
flask-socketio
psutil
werkzeug
PyJWT
```
