*** Begin Patch
*** Update File: README.md
@@
 ## البناء من المصدر
@@
 open ForgeSignMobile.xcodeproj
 ```
 
 افتح المشروع في Xcode وابنِ Scheme باسم `ForgeSignMobile`. اسم التطبيق الناتج للمستخدم هو **iStore**. إعدادات التوقيع داخل الم�[...]
+
+## Cloudflare R2 (optional) — upload/install flow
+
+iStore can upload signed IPAs to Cloudflare R2 and use a time-limited presigned URL in the install manifest.
+
+- Create a Cloudflare R2 bucket.
+- Create S3-compatible API keys (Access Key ID and Secret Access Key) in Cloudflare.
+- Your R2 endpoint typically looks like: https://<account>.r2.cloudflarestorage.com
+- Copy `App/Config.example.swift` → `App/Config.swift` and fill:
+  - endpoint = `"https://<account>.r2.cloudflarestorage.com"`
+  - accessKeyId = `"<your access key id>"`
+  - secretAccessKey = `"<your secret>"`
+  - bucket = `"<your bucket name>"`
+  - region = `"auto"`
+- Build and run on a real iOS device (itms-services installation only works on device). The app uploads the signed IPA to R2, generates a presigned (time-limited) GET URL for the manifest `fetchurl`, hands off to iOS via `itms-services`, and removes the uploaded object automatically after install or after the configured fallback timeout.
*** End Patch