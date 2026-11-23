# SCS Daily Expense — GitHub Pages + Supabase

গুগল শিট + Apps Script বাদ। এখন:
- **ফ্রন্টএন্ড** → GitHub Pages (স্ট্যাটিক ফাইল: `index.html`, `style.css`, `app.js`, `config.js`)
- **ডাটাবেজ + লজিক** → Supabase (Postgres)। Code.gs এর সব ফাংশন `supabase_setup.sql` এ `api_*` নামে আছে (পিন, সেশন, সাবমিট/অ্যাপ্রুভ/রিটার্ন, ড্যাশবোর্ড ইত্যাদি)
- **রিয়েল টাইম** → কেউ কিছু বদলালে অন্য ডিভাইসে নিজে থেকে রিফ্রেশ হয়

## ধাপ ১ — Supabase
1. supabase.com এ প্রজেক্ট খুলুন।
2. **SQL Editor > New query** এ `supabase_setup.sql` পুরোটা পেস্ট করে **Run**।
3. **Project Settings > API** থেকে `Project URL` ও `anon public key` কপি করুন।

## ধাপ ২ — config.js
`config.js` এ URL ও anon key বসান (service_role key কখনো নয়)।

## ধাপ ৩ — GitHub Pages
1. নতুন repo বানিয়ে এই ফোল্ডারের সব ফাইল (`migrate_from_sheet.gs` ছাড়া) আপলোড করুন।
2. **Settings > Pages > Deploy from a branch > main / (root)** → Save।
3. কিছুক্ষণ পর `https://<username>.github.io/<repo>/` এ অ্যাপ চালু।

## ধাপ ৪ — পুরনো ডাটা আনা (ঐচ্ছিক)
পুরনো শিটের Apps Script এ `migrate_from_sheet.gs` পেস্ট করে URL ও **service_role** key বসিয়ে `migrateAll` চালান। শেষে স্ক্রিপ্টটি মুছে দিন। (এমপ্লয়ি, ভাউচার, আইটেম, সেটিংস ও পিন-হ্যাশ সব আসবে, তাই আগের পিনই চলবে।)

## পিন
ডিফল্ট: ইউজার `2019`, অ্যাডমিন `2026`। ভুলে গেলে SQL Editor এ:
`delete from settings where key in ('admin_pin_hash','user_pin_hash');`

## নিরাপত্তা নোট
- টেবিলে সরাসরি অ্যাক্সেস বন্ধ (RLS); ব্রাউজার শুধু `api_*` ফাংশন ও একটি খালি `change_ping` সিগন্যাল দেখতে পায়।
- সেশন টোকেন Supabase এর `sessions` টেবিলে, মেয়াদ ৬ ঘণ্টা (আগের মতো)।
