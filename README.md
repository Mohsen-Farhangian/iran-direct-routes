# Iran Direct Routes

Split-tunnel helper for **any full-tunnel VPN on Windows**: Iranian IPv4 destinations use your local ISP/LAN; everything else stays on the VPN.

ابزار split-tunnel برای **هر VPN تمام‌تونل روی ویندوز**: مقصدهای IPv4 ایرانی از اینترنت محلی می‌روند؛ بقیه ترافیک روی VPN می‌ماند.

[فارسی](#فارسی) · [English](#english)

This is **not** limited to SoftEther. It works with SoftEther, OpenVPN, WireGuard, Cisco AnyConnect, and similar clients that take over the Windows default route (`0.0.0.0/0`). Clash / v2ray / sing-box already have their own `geosite:ir` / Direct rules — use those instead of this script.

---

## فارسی

### این پروژه چیست؟

وقتی یک VPN تمام‌تونل وصل می‌شود، ویندوز معمولاً مسیر پیش‌فرض را روی آداپتور VPN می‌گذارد و **کل اینترنت** از تونل می‌رود. این اسکریپت رنج‌های IPv4 اعلام‌شدهٔ ایران را دانلود می‌کند و برایشان مسیر مشخص‌تری از **گیت‌وی شبکه محلی** می‌سازد. ترافیک خارجی همان VPN می‌ماند.

با SoftEther تست شده، ولی به تنظیمات خود VPN دست نمی‌زند؛ فقط جدول مسیر ویندوز را عوض می‌کند.

### پیش‌نیاز

- ویندوز ۱۰ یا ۱۱
- هر VPN که ترافیک کل اینترنت را از تونل بفرستد (SoftEther، OpenVPN، WireGuard، AnyConnect و مشابه)
- دسترسی Administrator (برای `route add` / `route delete`)
- اینترنت برای دانلود لیست IP (بار اول و هر بار `Apply`)

### نصب و استفاده

1. مخزن را clone یا ZIP را باز کنید.
2. VPN را وصل کنید (یا بعداً وصل کنید؛ مسیرهای ایران روی کارت LAN می‌مانند).
3. روی `Apply-IranDirect.cmd` دوبار کلیک کنید و UAC را تأیید کنید.
4. اختیاری: `Install-LogonTask.cmd` را اجرا کنید تا بعد از ورود به ویندوز مسیرها دوباره اعمال شوند (مسیرها persistent نیستند و با ری‌استارت پاک می‌شوند).

برداشتن:

- `Remove-IranDirect.cmd` مسیرهایی را که آخرین `Apply` ساخته حذف می‌کند.
- برای برداشتن تسک:

```powershell
powershell -ExecutionPolicy Bypass -File .\IranDirect.ps1 -Action UninstallTask
```

(از PowerShell اجرا‌شده به‌عنوان Administrator)

وضعیت:

```powershell
powershell -ExecutionPolicy Bypass -File .\IranDirect.ps1 -Action Status
```

### لیست IP از کجاست؟

فایل زنده:

https://raw.githubusercontent.com/farshidmousavii/iran-ip-ranges/main/dist/raw/ipv4.txt

پروژهٔ [farshidmousavii/iran-ip-ranges](https://github.com/farshidmousavii/iran-ip-ranges) prefixهای کشور `IR` را از [RIPE Stat](https://stat.ripe.net/) می‌گیرد. این لیست «همه دامنه‌های `.ir`» نیست؛ رنج‌هایی است که در BGP به‌نام ایران اعلام شده‌اند.

### محدودیت‌ها

- مسیریابی ویندوز بر اساس **IP** است، نه دامنه. `*.ir` را نمی‌توان با `route add` اضافه کرد.
- اگر سایتی `.ir` باشد ولی روی CDN خارجی (مثلاً Cloudflare) باشد، هنوز از VPN می‌رود.
- IPv6 پوشش داده نشده است.
- گیت‌وی LAN به‌صورت خودکار از کارت Ethernet/Wi-Fi پیدا می‌شود. اگر لپ‌تاپ را به شبکهٔ دیگری ببرید، قبل از `Apply` دوباره یا یک‌بار `Remove` کنید.
- تنظیمات خود برنامهٔ VPN عوض نمی‌شود.
- برای Clash / sing-box / v2ray از قانون دامنهٔ خودشان (`geosite:ir`) استفاده کنید.

### فایل‌ها

| فایل | کار |
|------|-----|
| `IranDirect.ps1` | منطق اصلی |
| `Apply-IranDirect.cmd` | اعمال مسیرها (با UAC) |
| `Remove-IranDirect.cmd` | حذف مسیرها |
| `Install-LogonTask.cmd` | تسک زمان‌بندی‌شده هنگام ورود به ویندوز |

لیست رنج‌های اعمال‌شده این‌جا ذخیره می‌شود تا `Remove` فقط همان‌ها را پاک کند:

`%LOCALAPPDATA%\IranDirectRoutes\applied-cidrs.txt`

### تست سریع

در PowerShell (VPN روشن):

```powershell
Find-NetRoute -RemoteIPAddress 1.1.1.1
Find-NetRoute -RemoteIPAddress 217.218.127.127
```

انتظار: `1.1.1.1` از آداپتور VPN، آدرس ایرانی از Ethernet/Wi-Fi و گیت‌وی محلی.

### سلب مسئولیت

استفاده بر عهدهٔ خودتان است. لیست IP تضمین geolocation کامل نیست و ممکن است با تغییر تخصیص RIPE ناقص یا قدیمی شود. برای تازه‌سازی دوباره `Apply` را بزنید.

---

## English

### What this does

Any full-tunnel VPN on Windows usually installs a **default route** on the VPN adapter, so all IPv4 internet goes through the tunnel. This script is VPN-agnostic: it only changes the Windows routing table.

Windows prefers a **more-specific** route over `0.0.0.0/0`. This script:

1. Detects the up physical adapter (skips VPN/TAP/Wintun/WireGuard/OpenVPN/SoftEther).
2. Finds that adapter’s LAN gateway (even when the VPN has removed the LAN default route).
3. Downloads announced Iranian IPv4 CIDRs.
4. Runs `route add … METRIC 5 IF <lan>` for each prefix.

Foreign destinations keep using the VPN default route.

Works with SoftEther, OpenVPN, WireGuard, AnyConnect, and similar clients. It does **not** replace Clash/sing-box/v2ray domain routing (`geosite:ir`).

### Requirements

- Windows 10 or 11
- A VPN that sends all internet traffic through the tunnel
- Administrator rights
- Network access to GitHub (to fetch the prefix list)

### Usage

1. Clone this repository (or extract a release ZIP).
2. Double-click `Apply-IranDirect.cmd` and accept UAC.
3. Optionally run `Install-LogonTask.cmd` so routes are re-applied at logon. Routes are **not** persistent (`route -p` is not used) so they disappear after reboot.

To undo:

- `Remove-IranDirect.cmd` deletes only prefixes recorded by the last Apply.
- `IranDirect.ps1 -Action UninstallTask` removes the scheduled task (elevated PowerShell).

```powershell
powershell -ExecutionPolicy Bypass -File .\IranDirect.ps1 -Action Status
powershell -ExecutionPolicy Bypass -File .\IranDirect.ps1 -Action Apply
powershell -ExecutionPolicy Bypass -File .\IranDirect.ps1 -Action Remove
```

### IP list source

https://raw.githubusercontent.com/farshidmousavii/iran-ip-ranges/main/dist/raw/ipv4.txt

Built from RIPE Stat country resource `IR` by [farshidmousavii/iran-ip-ranges](https://github.com/farshidmousavii/iran-ip-ranges). This is **not** a `.ir` domain list.

### Limits

- Routing is IP-based. You cannot `route add *.ir`.
- A `.ir` site hosted on a foreign CDN still goes through the VPN.
- IPv6 is not handled.
- If you change networks, run `Remove` then `Apply` again so the next hop matches the new gateway.
- The VPN app’s own settings are left untouched.

### Quick test

With the VPN connected:

```powershell
Find-NetRoute -RemoteIPAddress 1.1.1.1
Find-NetRoute -RemoteIPAddress 217.218.127.127
```

`1.1.1.1` should use the VPN adapter; the Iranian address should use LAN and your local gateway.

### License

MIT. Prefix data belongs to its upstream project and RIPE.

### Disclaimer

No geolocation or routing completeness is guaranteed. Prefixes change; re-run Apply to refresh.
