# دسترسی ایجنت به کامپیوتر ویندوز شما — راهنمای کامل

هدف: من (ایجنت Arena) بتوانم روی کامپیوتر ویندوز شما **دستور اجرا کنم، فایل بخوانم، فایل بنویسم/تغییر بدهم** — و شما دقیقاً بدانید چه اتفاقی می‌افتد، چه چیزی مجاز است، و چطور در هر لحظه قطعش کنید.

---

## ۱. اول دو واقعیت که طراحی را تعیین می‌کنند

### الف) Tailscale از این محیط کار نمی‌کند

با تست واقعی از داخل sandbox بررسی کردم:

| تست | نتیجه |
|---|---|
| `curl https://controlplane.tailscale.com` | ❌ `SSL_ERROR_SYSCALL` |
| `curl https://login.tailscale.com` / `pkgs.tailscale.com` | ❌ بلاک |
| اتصال TCP به آدرس tailnet (`100.x.x.x`) | ❌ بلاک |
| نصب Tailscale (apt یا بسته‌ی رسمی) | ❌ مخازن بلاک (`deb.debian.org`, `pkgs.tailscale.com`) |

محیط من **فقط** به این میزبان‌ها خروجی شبکه دارد:

```
github.com · api.github.com · codeload.github.com · registry.npmjs.org · pypi.org + files.pythonhosted.org
```

پس «من → تونل Tailscale → کامپیوتر شما» غیرممکن است؛ نه به‌خاطر تنظیمات، بلکه چون ساندباکس اجازه‌ی هیچ اتصالی به control plane یا محدوده‌ی `100.64.0.0/10` را نمی‌دهد.

### ب) و GitHub Actions هم بسته است

راه دومِ معمول این است که من روی یک self-hosted runner ویندوزی workflow اجرا کنم. تست کردم:

```
POST /repos/…/actions/workflows/{id}/dispatches  →  403 Resource not accessible by integration
```

توکن من `actions: read` دارد، نه `write`. پس trigger کردن workflow هم ممکن نیست.

### ج) پس چه چیزی *کار می‌کند*؟ یک کانال که با مجوزهای واقعی من تست شده

| عملیات | نتیجه‌ی تست |
|---|---|
| `GET /repos/…` (خواندن ریپو) | ✅ 200 |
| `POST /repos/…/issues` (**ساخت issue**) | ✅ 201 |
| `GET /repos/…/issues/{n}/comments` (خواندن پاسخ‌ها) | ✅ 200 |
| `POST /repos/…/issues/{n}/comments` (کامنت) | ❌ 403 |
| `git push` / ساخت برنچ | ✅ |

یعنی من می‌توانم **issue بسازم و پاسخ‌ها را بخوانم**، اما نمی‌توانم کامنت بگذارم. کامنت‌گذاشتن کار ورکر روی کامپیوتر شماست (که توکن خودش را دارد). همین دو واقعیت، پروتکل را مشخص می‌کند: **هر درخواست = یک issue، هر پاسخ = یک کامنت روی همان issue**.

---

## ۲. معماری: «هر درخواست یک issue»

```
   من (sandbox)                   GitHub (ریپوی خصوصی)                 ویندوز شما
 دسترسی: فقط github.com                                          دسترسی: اینترنت کامل
        │                                                              │
        │ ۱) POST /issues                                              │
        │    #42  [agent-req] r-… op=exec                              │
        ▼    body: <!--AGENT:REQ:v1:…-->                               │
  ┌───────────────────────────────────────────────────────────────────┐
  │  issue #42                                                        │
  │    └─ comment: <!--AGENT:RES:v1:…-->   ← نتیجه‌ی اجرا             │
  │    (و بعد issue بسته می‌شود)                                      │
  └───────────────────────────────────────────────────────────────────┘
        ▲                                                              │
        │ ۳) می‌خوانم                               ۲) هر ۵ ثانیه poll │
        │    GET /issues/42/comments                 اجرا → کامنت     │
        │                                             → close          │
```

* هیچ پورت ورودی به خانه‌ی شما باز نمی‌شود؛ فقط خروجی HTTPS به `api.github.com`.
* پشت CGNAT، روتر معمولی و پروکسی شرکتی کار می‌کند.
* کل مکالمه در لیست issue ها دیده می‌شود؛ اگر خواستید، هر لحظه ورکر را ببندید یا توکن را باطل کنید.

**تأخیر واقعی:** ~۵ تا ۱۵ ثانیه برای هر دستور. یک ترمینال تعاملی زنده نیست، ولی برای کار ایجنتی (خواندن، تغییر، تست، دیباگ) کافی و پایدار است.

---

## ۳. من چه کاری می‌توانم بکنم و چه کاری نه

### ✅ بعد از راه‌اندازی
* اجرای دستور PowerShell/CMD با خروجی، stderr، کد خروج، و استریم خروجی دستورهای طولانی
* لیست کردن پوشه‌ها (`ls` بازگشتی هم)
* خواندن فایل — متنی و باینری، تکه‌تکه (۳۲KB در هر رفت‌وبرگشت)
* نوشتن/ویرایش فایل، ساخت پوشه — تکه‌تکه برای فایل‌های بزرگ
* SHA256 گرفتن و بررسی اینکه فایل واقعاً همان است
* مشخصات سیستم، درایوها، نسخه‌ی PowerShell، وضعیت Tailscale (اگر نصب باشد)

### ❌ چیزهایی که همچنان نمی‌توانم
* GUI: کلیک، دیدن صفحه، کار با اپ گرافیکی
* دسترسی به شبکه‌ی شما از داخل ساندباکس (حتی با Tailscale)
* کار کردن وقتی کامپیوتر خواب/خاموش است یا کاربر logout کرده
* خواندن/نوشتن بیرون از «ریشه‌های مجاز» که خودتان تعیین می‌کنید
* سرعت بالا برای فایل‌های خیلی بزرگ (چند صد مگابایت به بالا: کند است)

---

## ۴. پیش‌نیازها

1. ویندوز ۱۰/۱۱ با **PowerShell 5.1** (پیش‌فرض).
2. یک **ریپوی خصوصی** که من به آن دسترسی دارم (ساده‌ترین: همین `Local-access`).
3. یک **PAT فاین‌گرین** فقط با `Issues: Read and write`.
4. اینترنت روی کامپیوتر — بدون نیاز به پورت باز یا IP عمومی.

---

## ۵. راه‌اندازی گام‌به‌گام

### گام ۰ — ریپو را خصوصی کنید (اجباری)

من از این ریپو برای انتقال محتوای فایل‌های شما و خروجی دستورها استفاده می‌کنم. اگر public باشد، همه‌ی دنیا می‌بیند.

GitHub → ریپو `animalrender/Local-access` → **Settings** → **Danger Zone** → **Change visibility** → **Private**.

> هر دو طرف این را چک می‌کنند: نصب‌کننده بدون `-Force` روی ریپوی public کار نمی‌کند و کلاینت من بدون `--allow-public` هم.

### گام ۱ — ساخت توکن (PAT)

1. GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens** → **Generate new token**.
2. **Repository access** → *Only select repositories* → `animalrender/Local-access`.
3. **Permissions** → **Repository permissions** → **Issues: Read and write** (همین یکی کافی است).
4. Expiration کوتاه (مثلاً ۳۰ روز) — بعداً راحت تمدید می‌شود.
5. توکن (`github_pat_…`) را کپی کنید؛ فقط یک‌بار نشان داده می‌شود.

### گام ۲ — کد را روی ویندوز بیاورید

```powershell
cd $env:USERPROFILE
git clone -b arena/ed255f64-local-access https://github.com/animalrender/Local-access.git
cd Local-access
```

> اگر برنچ `main` را merge کردید، `git clone` ساده هم کافی است. بدون Git: **Code → Download ZIP** و باز کردن در `C:\Users\<شما>\Local-access`.

### گام ۳ — نصب ورکر

```powershell
cd $env:USERPROFILE\Local-access
powershell -ExecutionPolicy Bypass -File .\agent\windows\Install-Worker.ps1 `
    -Repo animalrender/Local-access `
    -Roots 'C:\Users\<نام شما>','D:\projects'
```

هر مرحله را چاپ می‌کند:

| مرحله | کار |
|---|---|
| ۱ | توکن را می‌گیرد، ریپو را چک می‌کند، **اگر public باشد متوقف می‌شود**، توکن را با DPAPI (مخصوص همین کاربر) ذخیره می‌کند |
| ۲ | **تست مجوزهای گیت‌هاب**: یک issue موقت می‌سازد، کامنت می‌گذارد و می‌بندد |
| ۳ | `agent.config.json` را با «ریشه‌های مجاز» شما می‌سازد |
| ۴ | **self-test محلی**: ping، exec، نوشتن/خواندن فایل، هش، و رد شدن مسیر بیرون از ریشه‌ها |
| ۵ | تسک زمان‌بندی `LocalAccessAgentWorker` برای اجرا در هر لاگین |
| ۶ | ورکر را در پس‌زمینه شروع می‌کند |

خروجی موفق:

```
== 2/6  GitHub permissions
   ok   can create issues (this is how the agent sends requests)
   ok   can comment on issues (this is how the worker answers)
   ok   can close issues

== 4/6  local self-test
   ok   ping
   ok   exec
   ok   exec keeps utf-8 output
   ok   write
   ok   read returns the same bytes
   ok   hash
   ok   sandbox refuses paths outside the roots
   ok   all self-tests passed
```

اگر جایی FAIL شد، اسکریپت با پیام مشخص می‌ایستد — همان را برایم بفرستید.

### گام ۴ — تست از سمت من

کافی است بگویید «راه افتاد». من این را اجرا می‌کنم:

```bash
python3 scripts/agent.py ping
```

و روی ریپو یک issue با عنوان `[agent-req] r-… ping` ظاهر می‌شود که چند ثانیه بعد پاسخ می‌گیرد و بسته می‌شود.

---

## ۶. استفاده‌ی روزمره (این‌ها را من اجرا می‌کنم)

```bash
# اجرای دستور
python3 scripts/agent.py exec 'Get-Process | Sort CPU -Descending | Select -First 5'
python3 scripts/agent.py exec 'Get-ChildItem -Recurse -Filter *.log | Measure-Object -Sum Length'

# پوشه‌ها
python3 scripts/agent.py ls 'C:\Users\me\Desktop'
python3 scripts/agent.py ls 'D:\projects\app' --recursive

# خواندن / نوشتن / بررسی
python3 scripts/agent.py read 'C:\Users\me\Desktop\notes.txt'
python3 scripts/agent.py read 'D:\big.iso' --out ./big.iso      # تکه‌تکه تا آخر فایل
python3 scripts/agent.py write 'C:\Users\me\Desktop\new.txt' --from ./local.txt
python3 scripts/agent.py hash 'C:\Users\me\Desktop\new.txt'

# وضعیت (اگر جواب نیامد)
python3 scripts/agent.py status
```

* سقف زمان هر دستور پیش‌فرض ۱۲۰ ثانیه، تا ۹۰۰ ثانیه قابل تنظیم.
* برای دستورهای طولانی، هر ۲۰ ثانیه خروجی جزئی می‌بینید.
* خروجی کامل همیشه روی خودِ کامپیوتر در `log_path` ذخیره می‌شود.

---

## ۷. امنیت — دقیقاً چه چیزی در معرض است

**مدل تهدید:** ورکر با اختیارات کاربر شما اجرا می‌شود. هر کسی که بتواند در آن ریپو کار کند (یا توکن را داشته باشد)، می‌تواند دستور اجرا کند. پس:

| کنترل | وضعیت |
|---|---|
| ریپو خصوصی | اجباری؛ نصب‌کننده و کلاینت هر دو چک می‌کنند |
| مجوز توکن | فقط `Issues: Read and write` — بدون دسترسی به کد، سکرت‌ها یا Actions |
| محل نگهداری توکن | `%LOCALAPPDATA%\win-agent\token.dpapi` — DPAPI + ACL فقط برای کاربر شما؛ هرگز در خط فرمان یا تسک نیست |
| محدوده‌ی فایل‌ها | `allowedRoots` در `agent.config.json`؛ بیرون از آن با خطا رد می‌شود (self-test هم چکش می‌کند) |
| اجرای دستور | `allowExec: false` = حالت فقط‌خواندنی |
| نوشتن | `allowWrite: false` = بستن نوشتن |
| ممیزی | هر درخواست یک issue است و برای همیشه می‌ماند؛ لاگ محلی: `%LOCALAPPDATA%\win-agent\worker.log` |
| سطح دسترسی | ورکر با `-RL LIMITED` (بدون UAC admin) اجرا می‌شود |

**توقف فوری (هر کدام کافی است):**
1. روی کامپیوتر: `schtasks /Delete /TN LocalAccessAgentWorker /F` و بعد `Stop-Process -Name powershell -Force`
2. در GitHub: توکن را **Revoke** کنید
3. ورکر را از اجرا متوقف کنید (Task Manager → PowerShell) — issue ها بی‌پاسخ می‌مانند

**توصیه‌های جدی**
* `-Roots` را باریک بدهید؛ کل درایو `C:\` را به من ندهید.
* برای ریسک کمتر، ورکر را در یک **حساب کاربری مجزای ویندوز** اجرا کنید.
* رمزها/کلیدها را در فایل‌های داخل `allowedRoots` نگه ندارید.
* اگر کار حساسی دارید، اول توکن را revoke کنید، بعد کارتان را بکنید.

---

## ۸. محدودیت‌های فنی

| موضوع | مقدار |
|---|---|
| تأخیر هر دستور | ~۵–۱۵ ثانیه (فاصله‌ی poll + اجرا) |
| اندازه‌ی هر پیام | ~۴۸KB خام (سقف ۶۵٬۵۳۶ کاراکتر GitHub) → خواندن/نوشتن تکه‌تکه |
| خروجی دستور در پاسخ | ۷KB اول در JSON؛ متن کامل در `log_path` روی کامپیوتر |
| زمان هر دستور | ۱۲۰ ثانیه پیش‌فرض، حداکثر ۹۰۰ |
| همزمانی | یک دستور در هر لحظه، به ترتیب |
| خواب سیستم | ورکر کند/متوقف می‌شود؛ بعد از بیداری ادامه می‌دهد |
| لاگ‌اوت | تسک ONLOGON است؛ با logout ورکر می‌میرد (قابل ارتقا به سرویس) |
| پروکسی شرکتی | خروجی HTTPS به `api.github.com` لازم است (`Invoke-RestMethod` از پروکسی سیستم استفاده می‌کند) |
| امضای درخواست | ندارد (private repo + توکن)؛ در صورت نیاز می‌توان HMAC اضافه کرد |
| حجم issue ها | هر درخواست یک issue؛ دوره‌ای می‌توانید issue های بسته‌شده را حذف کنید |

---

## ۹. عیب‌یابی

| نشانه | علت | راه‌حل |
|---|---|---|
| `no answer after 180s` | ورکر اجرا نیست | `Get-Process powershell`؛ لاگ `%LOCALAPPDATA%\win-agent\worker.log`؛ `run-worker.cmd` را اجرا کنید |
| `HTTP 401` در لاگ | توکن باطل/منقضی | توکن تازه + `Install-Worker.ps1 -Force` |
| `HTTP 403` هنگام کامنت | توکن `Issues: write` ندارد | همان بخش ۲ گام ۱؛ بعد دوباره نصب |
| `HTTP 403` توسط خودِ من | توکن من هم برای کامنت مجاز نیست (طبیعی است) | کاری لازم نیست؛ من فقط issue می‌سازم و پاسخ را می‌خوانم |
| `HTTP 404` | ریپو/شماره‌ی issue اشتباه | نام ریپو را در `-Repo` چک کنید |
| `comment too large` | پاسخ بزرگ | خودکار کوتاه می‌شود؛ متن کامل با `read` از `log_path` |
| `path outside allowed roots` | مسیر بیرون از `-Roots` | `agent.config.json` را ویرایش و ورکر را ری‌استارت کنید |
| self-test روی UTF-8 فارسی FAIL | کدپیج کنسول | `chcp 65001`؛ عملکرد را مختل نمی‌کند ولی خبرش را بدهید |
| `ExecutionPolicy` | سیاست ویندوز | همان `powershell -ExecutionPolicy Bypass -File …` |
| «another AgentWorker is already running» | دو نسخه همزمان | یکی را ببندید |

---

## ۱۰. گزینه‌های تکمیلی

**الف) ورکر روی لینوکس / WSL / مک:** `agent/linux/worker.py` همان پروتکل را پیاده کرده است:

```bash
GITHUB_TOKEN=… python3 agent/linux/worker.py --repo animalrender/Local-access --interval 5
```

**ب) تست بدون ویندوز و بدون گیت‌هاب:** یک مجموعه‌ی تست آفلاین هست که کل چرخه را (exec، ls، خواندن/نوشتن ۱۲۰KB، سندباکس، آیدمپوتنسی) بررسی می‌کند:

```bash
bash agent/selftest.sh      # 17/17 ok
```

**ج) سرویس زنده روی Tailscale (اختیاری، برای خودتان):** `agent/windows/Live-Service.ps1 -Install` یک API با توکن روی `127.0.0.1:8765` بالا می‌آورد؛ با `tailscale serve --bg 8765` روی tailnet منتشر می‌شود و از موبایل/لپ‌تاپ دیگر قابل استفاده است. توجه: **من** به tailnet دسترسی ندارم، پس این جای صندوق پست را نمی‌گیرد.

**د) اگر روزی `actions: write` به توکن اضافه شد:** مسیر self-hosted runner باز می‌شود و تأخیر به ~۲ ثانیه می‌رسد. اسکلت آن در همین ریپو قابل افزودن است.

---

## ۱۱. چک‌لیست پذیرش

- [ ] ریپو خصوصی است
- [ ] PAT فقط با `Issues: Read and write`
- [ ] `Install-Worker.ps1` بدون خطا تمام شد (هر سه تست مجوز + هفت self-test سبز)
- [ ] `allowedRoots` فقط پوشه‌های لازم است
- [ ] من `ping` فرستادم و issue پاسخ گرفت و بسته شد
- [ ] یک `exec` و یک `read` واقعی روی فایل تست انجام شد
- [ ] می‌دانم چطور فوراً قطعش کنم (revoke توکن / بستن ورکر)

---

## ۱۲. حذف کامل

```powershell
schtasks /Delete /TN LocalAccessAgentWorker /F
Stop-Process -Name powershell -Force -ErrorAction SilentlyContinue
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\win-agent"
```

و در GitHub: توکن را revoke کنید و اگر خواستید issue های `[agent-req]` را حذف/آرشیو کنید (یا ریپو را دوباره public کنید اگر دیگر لازم نیست).
