// Supabase Dashboard > Project Settings > API থেকে এই দুটো মান বসান।
// anon (public) key দেখা গেলে সমস্যা নেই — ডাটা RLS ও PIN দিয়ে সুরক্ষিত। কখনো service_role key এখানে দেবেন না।
window.SCS_CONFIG = {
  SUPABASE_URL: "https://YOUR_PROJECT_REF.supabase.co",
  SUPABASE_ANON_KEY: "YOUR_ANON_PUBLIC_KEY"
};
