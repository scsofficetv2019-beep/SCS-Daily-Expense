-- =====================================================================
--  SCS Daily Expense — Supabase setup (Code.gs এর পুরো লজিক এখানে)
--  ব্যবহার: Supabase Dashboard > SQL Editor > New query > পুরোটা পেস্ট > Run
--  ডিফল্ট পিন: ইউজার 2019, অ্যাডমিন 2026
--  নিরাপত্তা: টেবিলে সরাসরি অ্যাক্সেস বন্ধ (RLS)। সব কাজ নিচের api_* ফাংশনের মাধ্যমে।
-- =====================================================================
create extension if not exists pgcrypto with schema extensions;

-- ---------------------------- TABLES ---------------------------------
create table if not exists employees (
  emp_id text primary key, name text not null default '', designation text not null default '',
  department text not null default '', mobile text not null default '', pin text not null default '',
  active boolean not null default true, created_at text not null default '', updated_at text not null default '',
  sort_order int
);
create table if not exists vouchers (
  seq bigint generated always as identity,
  voucher_id text primary key, date text not null default '', emp_id text not null default '',
  emp_name text not null default '', designation text not null default '', status text not null default 'Draft',
  total numeric not null default 0, item_count int not null default 0,
  created_at text not null default '', updated_at text not null default '', submitted_at text not null default '',
  approved_at text not null default '', approved_by text not null default '', returned_at text not null default '',
  admin_note text not null default '', submit_count int not null default 0, title text not null default '',
  voucher_no text not null default '', appr1_at text not null default '', appr2_at text not null default '',
  user_sign text not null default ''
);
create index if not exists vouchers_date_idx on vouchers(date);
create index if not exists vouchers_emp_idx on vouchers(emp_id);
create table if not exists items (
  seq bigint generated always as identity,
  item_id text primary key, voucher_id text not null default '', date text not null default '', emp_id text not null default '',
  category text not null default '', description text not null default '', payment_mode text not null default '',
  amount numeric not null default 0, remarks text not null default '', created_at text not null default '',
  updated_at text not null default '', edited_by text not null default '', quantity numeric not null default 0,
  rate numeric not null default 0
);
create index if not exists items_voucher_idx on items(voucher_id);
create table if not exists settings (key text primary key, value text not null default '', updated_at text not null default '');
create table if not exists activity_log (
  id bigint generated always as identity primary key, log_time text not null default '', voucher_id text not null default '',
  action text not null default '', by_user text not null default '', note text not null default ''
);
create table if not exists sessions (token uuid primary key default gen_random_uuid(), role text not null, expires_at timestamptz not null);
create table if not exists change_ping (id int primary key, ts timestamptz not null default now());
insert into change_ping(id) values (1) on conflict do nothing;

-- RLS চালু, কোনো টেবিলে সরাসরি পড়া/লেখা নেই (শুধু change_ping এ খালি "সিগন্যাল" পড়া যায় — রিয়েল টাইমের জন্য)
alter table employees enable row level security;  alter table vouchers enable row level security;
alter table items enable row level security;      alter table settings enable row level security;
alter table activity_log enable row level security; alter table sessions enable row level security;
alter table change_ping enable row level security;
revoke all on all tables in schema public from anon, authenticated;
drop policy if exists ping_read on change_ping;
create policy ping_read on change_ping for select to anon using (true);
grant select on change_ping to anon;

-- ------------------------- REALTIME TRIGGERS -------------------------
create or replace function _ping() returns trigger language plpgsql security definer set search_path = public as $$
begin update change_ping set ts = now() where id = 1; return null; end $$;
do $$ declare t text; begin
  foreach t in array array['vouchers','items','employees','settings'] loop
    execute format('drop trigger if exists trg_ping on %I', t);
    execute format('create trigger trg_ping after insert or update or delete on %I for each statement execute function _ping()', t);
  end loop;
end $$;
do $$ begin
  alter publication supabase_realtime add table change_ping;
exception when duplicate_object then null; end $$;

-- ---------------------------- HELPERS --------------------------------
create or replace function _now() returns text language sql stable as $$ select to_char(now() at time zone 'Asia/Dhaka','YYYY-MM-DD HH24:MI:SS') $$;
create or replace function _today() returns text language sql stable as $$ select to_char(now() at time zone 'Asia/Dhaka','YYYY-MM-DD') $$;
create or replace function _str(v text) returns text language sql immutable as $$ select trim(coalesce(v,'')) $$;
create or replace function _num(v text) returns numeric language plpgsql immutable as $$
begin return coalesce(nullif(regexp_replace(coalesce(v,''),'[^0-9.\-]','','g'),'')::numeric,0);
exception when others then return 0; end $$;
create or replace function _hash(t text) returns text language sql immutable set search_path = public, extensions as $$ select encode(extensions.digest(t,'sha256'),'hex') $$;
create or replace function _gs(k text, d text) returns text language sql stable as $$ select coalesce((select nullif(value,'') from settings where key = k), d) $$;
create or replace function _ss(k text, v text) returns void language sql as $$
  insert into settings(key,value,updated_at) values (k,v,_now()) on conflict (key) do update set value = excluded.value, updated_at = excluded.updated_at $$;
create or replace function _log(vid text, act text, by_ text, nt text) returns void language sql as $$
  insert into activity_log(log_time,voucher_id,action,by_user,note) values (_now(), coalesce(vid,''), act, by_, coalesce(nt,'')) $$;

create or replace function _check_pin(kind text, pin text) returns boolean language plpgsql stable as $$
declare h text := _gs(case when kind='admin' then 'admin_pin_hash' else 'user_pin_hash' end, '');
begin
  if h = '' then return pin = case when kind='admin' then '2026' else '2019' end; end if;
  return _hash(pin) = h;
end $$;

create or replace function _need(tok text, need_role text default null) returns text language plpgsql security definer set search_path = public as $$
declare r text;
begin
  select s.role into r from sessions s where s.token::text = coalesce(tok,'') and s.expires_at > now();
  if r is null then raise exception 'AUTH: সেশন শেষ হয়ে গেছে, আবার পিন দিয়ে লগইন করুন।'; end if;
  if need_role = 'admin' and r <> 'admin' then raise exception 'অ্যাডমিন পিন প্রয়োজন।'; end if;
  update sessions set expires_at = now() + interval '6 hours' where token::text = tok;
  return r;
end $$;

create or replace function _new_token(r text) returns text language plpgsql security definer set search_path = public as $$
declare t uuid := gen_random_uuid();
begin
  delete from sessions where expires_at < now();
  insert into sessions(token,role,expires_at) values (t, r, now() + interval '6 hours');
  return t::text;
end $$;

create or replace function _can_edit(r text, st text) returns boolean language sql immutable as $$ select r = 'admin' or st in ('Draft','Returned') $$;

create or replace function _voucher_out(v vouchers) returns jsonb language sql stable as $$
  select jsonb_build_object('id',v.voucher_id,'date',v.date,'empId',v.emp_id,'empName',v.emp_name,'designation',v.designation,
    'status',coalesce(nullif(v.status,''),'Draft'),'total',v.total,'itemCount',v.item_count,'createdAt',v.created_at,'updatedAt',v.updated_at,
    'submittedAt',v.submitted_at,'approvedAt',v.approved_at,'approvedBy',v.approved_by,'returnedAt',v.returned_at,'adminNote',v.admin_note,
    'submitCount',v.submit_count,'title',v.title,'voucherNo',v.voucher_no,'appr1At',v.appr1_at,'appr2At',v.appr2_at,'hasSign',v.user_sign <> '') $$;

create or replace function _item_out(i items) returns jsonb language sql stable as $$
  select jsonb_build_object('id',i.item_id,'voucherId',i.voucher_id,'date',i.date,'empId',i.emp_id,'category',i.category,'description',i.description,
    'paymentMode',i.payment_mode,'amount',i.amount,'qty',i.quantity,'rate',i.rate,'remarks',i.remarks,'createdAt',i.created_at,
    'updatedAt',i.updated_at,'editedBy',i.edited_by) $$;

create or replace function _full_voucher(vid text) returns jsonb language plpgsql stable as $$
declare v vouchers; o jsonb;
begin
  select * into v from vouchers where voucher_id = vid;
  if not found then return null; end if;
  o := _voucher_out(v) || jsonb_build_object('userSign', v.user_sign);
  o := o || jsonb_build_object(
    'items', coalesce((select jsonb_agg(_item_out(i) order by i.created_at, i.seq) from items i where i.voucher_id = vid), '[]'::jsonb),
    'log', coalesce((select jsonb_agg(jsonb_build_object('time',l.log_time,'action',l.action,'by',l.by_user,'note',l.note) order by l.id)
                     from activity_log l where l.voucher_id = vid), '[]'::jsonb));
  return o;
end $$;

create or replace function _recalc(vid text) returns void language sql as $$
  update vouchers set total = round(coalesce((select sum(amount) from items where voucher_id = vid),0),2),
    item_count = (select count(*) from items where voucher_id = vid), updated_at = _now() where voucher_id = vid $$;

create or replace function _emps(with_pin boolean) returns jsonb language sql stable as $$
  select coalesce(jsonb_agg(
    jsonb_build_object('id',e.emp_id,'name',e.name,'designation',e.designation,'department',e.department,'mobile',e.mobile,
      'active',e.active,'hasPin',e.pin <> '','order',coalesce(e.sort_order,1000000000))
    || case when with_pin then jsonb_build_object('pin',e.pin) else '{}'::jsonb end
    order by coalesce(e.sort_order,1000000000), e.emp_id), '[]'::jsonb) from employees e $$;

create or replace function _public_settings() returns jsonb language plpgsql stable as $$
declare cats jsonb; sig jsonb; pm jsonb;
begin
  begin cats := _gs('categories','[]')::jsonb; exception when others then cats := '[]'; end;
  if jsonb_typeof(cats) <> 'array' or jsonb_array_length(cats) = 0 then
    cats := '["Conveyance / যাতায়াত","Food / খাবার","Mobile Bill / মোবাইল বিল","Fuel / জ্বালানি","Office Supplies / অফিস সামগ্রী","Labour / শ্রমিক","Carrying / মালামাল পরিবহন","Entertainment / আপ্যায়ন","Repair & Maintenance / মেরামত","Others / অন্যান্য"]'::jsonb;
  end if;
  begin sig := _gs('signature_config','null')::jsonb; exception when others then sig := null; end;
  if sig is null or jsonb_typeof(sig) <> 'array' or jsonb_array_length(sig) = 0 then
    sig := '[{"label":"Prepared By","name":"","sub":"Employee"},{"label":"Checked By","name":"","sub":"Accounts"},{"label":"Approved By","name":"","sub":"Admin"},{"label":"Received By","name":"","sub":""}]'::jsonb;
  end if;
  begin pm := _gs('payment_modes','[]')::jsonb; exception when others then pm := '[]'; end;
  if jsonb_typeof(pm) <> 'array' or jsonb_array_length(pm) = 0 then pm := '["Cash","bKash","Nagad","Bank","Card"]'::jsonb; end if;
  return jsonb_build_object(
    'companyName',_gs('company_name','Swarup Construction Solution'),'tagline',_gs('tagline','Honesty is our Business Capital'),
    'companyAddress',_gs('company_address',''),'voucherTitle',_gs('voucher_title','DAILY EXPENSE VOUCHER'),
    'paymentModes',pm,'categories',cats,'signatures',sig,'logo',_gs('logo_data_url',''),'adminPinLen',_gs('admin_pin_len','4'),
    'voucherPaper',_gs('voucher_paper','a4'),'voucherMode',_gs('voucher_mode','full'),
    'approvers',jsonb_build_array(
      jsonb_build_object('name',_gs('appr1_name','Ujjal Majumder'),'sign',_gs('appr1_sign','')),
      jsonb_build_object('name',_gs('appr2_name','Shamiron Halder'),'sign',_gs('appr2_sign',''))),
    'allowSameDayMulti',_gs('allow_same_day_multi','true') = 'true');
end $$;

create or replace function _create_voucher(emp text, d text, by_ text, ttl text) returns text language plpgsql as $$
declare e employees; base text; vid text; n int := 2;
begin
  select * into e from employees where emp_id = _str(emp);
  if not found then raise exception 'এমপ্লয়ি পাওয়া যায়নি: %', emp; end if;
  if _str(d) !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'সঠিক তারিখ দিন।'; end if;
  base := 'EXP-' || replace(_str(d),'-','') || '-' || regexp_replace(_str(emp),'[^A-Za-z0-9]','','g');
  vid := base;
  while exists (select 1 from vouchers where voucher_id = vid) loop vid := base || '-' || n; n := n + 1; end loop;
  insert into vouchers(voucher_id,date,emp_id,emp_name,designation,status,created_at,updated_at,title)
    values (vid,_str(d),e.emp_id,e.name,e.designation,'Draft',_now(),_now(),_str(ttl));
  perform _log(vid,'Draft Created',by_,'');
  return vid;
end $$;

create or replace function _next_voucher_no() returns text language plpgsql as $$
declare seq int := _num(_gs('voucher_seq','0'))::int + 1;
begin
  perform _ss('voucher_seq', seq::text);
  return 'SCSV' || to_char(now() at time zone 'Asia/Dhaka','YYYYMM') || '-' || lpad(seq::text,2,'0');
end $$;

-- ============================ PUBLIC API ============================
-- প্রতিটি ফাংশন একটি jsonb অ্যারে নেয় (Apps Script এর আর্গুমেন্ট ক্রমে)

create or replace function api_login(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare pin text := _str(args->>0);
begin
  if _check_pin('admin',pin) then return jsonb_build_object('ok',true,'role','admin','token',_new_token('admin')); end if;
  if _check_pin('user',pin) then return jsonb_build_object('ok',true,'role','user','token',_new_token('user')); end if;
  return jsonb_build_object('ok',false,'message','ভুল পিন! আবার চেষ্টা করুন।');
end $$;

create or replace function api_admin_unlock(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _need(args->>0);
  if not _check_pin('admin',_str(args->>1)) then return jsonb_build_object('ok',false,'message','ভুল অ্যাডমিন পিন!'); end if;
  return jsonb_build_object('ok',true,'role','admin','token',_new_token('admin'));
end $$;

create or replace function api_logout(args jsonb) returns jsonb language plpgsql security definer set search_path = public as $$
begin delete from sessions where token::text = coalesce(args->>0,''); return 'true'::jsonb; end $$;

create or replace function api_verify_admin_pin(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin perform _need(args->>0,'admin'); return to_jsonb(_check_pin('admin',_str(args->>1))); end $$;

create or replace function api_get_bootstrap(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0);
begin
  return jsonb_build_object('role',r,'employees',_emps(r='admin'),'settings',_public_settings(),'today',_today(),'serverTime',_now());
end $$;

create or replace function api_get_voucher(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare o jsonb;
begin
  perform _need(args->>0);
  o := _full_voucher(args->>1);
  if o is null then raise exception 'ভাউচার পাওয়া যায়নি: %', args->>1; end if;
  return o;
end $$;

create or replace function api_create_draft(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0);
begin
  perform pg_advisory_xact_lock(1);
  return _full_voucher(_create_voucher(args->>1,args->>2,case when r='admin' then 'Admin' else 'User' end,args->>3));
end $$;

create or replace function api_save_item(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); p jsonb := coalesce(args->1,'{}'); it jsonb := coalesce(args->1->'item','{}');
  v vouchers; vid text := _str(p->>'voucherId'); by_ text; q numeric; rt numeric; amt numeric; iid text; ex items;
begin
  perform pg_advisory_xact_lock(1);
  by_ := case when r='admin' then 'Admin' else 'User' end;
  if vid <> '' then
    select * into v from vouchers where voucher_id = vid;
    if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
    if not _can_edit(r,v.status) then raise exception 'এই ভাউচার সাবমিট হয়ে গেছে। এখন শুধু অ্যাডমিন এডিট করতে পারবেন।'; end if;
  elsif coalesce((p->>'newDraft')::boolean,false) then
    vid := _create_voucher(p->>'empId',p->>'date',by_,p->>'title');
  else
    select voucher_id into vid from vouchers where emp_id=_str(p->>'empId') and date=_str(p->>'date') and status in ('Draft','Returned') order by seq limit 1;
    if vid is null then vid := _create_voucher(p->>'empId',p->>'date',by_,null); end if;
  end if;
  q := _num(it->>'qty'); rt := _num(it->>'rate'); amt := _num(it->>'amount');
  if not (amt > 0) and q > 0 and rt > 0 then amt := round(q*rt,2); end if;
  if not (amt > 0) then raise exception 'টাকার পরিমাণ সঠিকভাবে দিন।'; end if;
  if _str(it->>'description') = '' and _str(it->>'category') = '' then raise exception 'খরচের বিবরণ লিখুন।'; end if;
  select * into v from vouchers where voucher_id = vid;
  if _str(it->>'id') <> '' then
    select * into ex from items where item_id = it->>'id' and voucher_id = vid;
    if not found then raise exception 'খরচটি পাওয়া যায়নি।'; end if;
    update items set category=_str(it->>'category'), description=_str(it->>'description'), payment_mode=_str(it->>'paymentMode'),
      amount=amt, quantity=case when q>0 then q else 0 end, rate=case when rt>0 then rt else 0 end, remarks=_str(it->>'remarks'),
      updated_at=_now(), edited_by=by_ where item_id = ex.item_id;
    iid := ex.item_id;
    if r='admin' and v.status <> 'Draft' then perform _log(vid,'Item Edited','Admin',_str(it->>'description')||' = '||amt); end if;
  else
    iid := 'IT-' || upper(substr(gen_random_uuid()::text,1,8));
    insert into items(item_id,voucher_id,date,emp_id,category,description,payment_mode,amount,quantity,rate,remarks,created_at,updated_at,edited_by)
      values (iid,vid,v.date,v.emp_id,_str(it->>'category'),_str(it->>'description'),_str(it->>'paymentMode'),amt,
        case when q>0 then q else 0 end,case when rt>0 then rt else 0 end,_str(it->>'remarks'),_now(),_now(),by_);
    if r='admin' and v.status <> 'Draft' then perform _log(vid,'Item Added','Admin',_str(it->>'description')||' = '||amt); end if;
  end if;
  perform _recalc(vid);
  return _full_voucher(vid) || jsonb_build_object('savedItemId', iid);
end $$;

create or replace function api_update_draft_header(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); vid text := args->>1; hd jsonb := coalesce(args->2,'{}'); v vouchers; e employees;
begin
  perform pg_advisory_xact_lock(1);
  select * into v from vouchers where voucher_id = vid;
  if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  if not _can_edit(r,v.status) then raise exception 'এই ভাউচার সাবমিট হয়ে গেছে। এখন আর এডিট করা যাবে না।'; end if;
  if _str(hd->>'empId') <> '' and _str(hd->>'empId') <> v.emp_id then
    select * into e from employees where emp_id = _str(hd->>'empId');
    if not found then raise exception 'এমপ্লয়ি পাওয়া যায়নি: %', hd->>'empId'; end if;
    v.emp_id := e.emp_id; v.emp_name := e.name; v.designation := e.designation;
  end if;
  if _str(hd->>'date') <> '' then
    if _str(hd->>'date') !~ '^\d{4}-\d{2}-\d{2}$' then raise exception 'সঠিক তারিখ দিন।'; end if;
    v.date := _str(hd->>'date');
  end if;
  if hd ? 'title' then v.title := _str(hd->>'title'); end if;
  update vouchers set emp_id=v.emp_id, emp_name=v.emp_name, designation=v.designation, date=v.date, title=v.title, updated_at=_now() where voucher_id = vid;
  update items set emp_id=v.emp_id, date=v.date where voucher_id = vid and (emp_id <> v.emp_id or date <> v.date);
  return _full_voucher(vid);
end $$;

create or replace function api_list_open_drafts(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _need(args->>0);
  return coalesce((select jsonb_agg(_voucher_out(v) order by v.date desc) from vouchers v where v.status in ('Draft','Returned')),'[]'::jsonb);
end $$;

create or replace function api_delete_item(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); vid text := args->>1; v vouchers; ex items;
begin
  perform pg_advisory_xact_lock(1);
  select * into v from vouchers where voucher_id = vid;
  if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  if not _can_edit(r,v.status) then raise exception 'সাবমিট করা ভাউচার থেকে ডিলিট করা যাবে না।'; end if;
  select * into ex from items where item_id = args->>2 and voucher_id = vid;
  if not found then raise exception 'খরচটি পাওয়া যায়নি।'; end if;
  delete from items where item_id = ex.item_id;
  if r='admin' and v.status <> 'Draft' then perform _log(vid,'Item Deleted','Admin',ex.description||' = '||ex.amount); end if;
  perform _recalc(vid);
  return _full_voucher(vid);
end $$;

create or replace function api_delete_voucher(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); vid text := args->>1; v vouchers;
begin
  perform pg_advisory_xact_lock(1);
  select * into v from vouchers where voucher_id = vid;
  if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  if r <> 'admin' and v.status <> 'Draft' then raise exception 'শুধু ড্রাফট ভাউচার ডিলিট করা যায়।'; end if;
  delete from items where voucher_id = vid;
  delete from vouchers where voucher_id = vid;
  perform _log(vid,'Voucher Deleted',case when r='admin' then 'Admin' else 'User' end,'');
  return 'true'::jsonb;
end $$;

create or replace function api_submit_voucher(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); vid text := args->>1; pin text := _str(args->>2); sg text := _str(args->>3);
  v vouchers; e employees; ok boolean := false; was_ret boolean;
begin
  perform pg_advisory_xact_lock(1);
  select * into v from vouchers where voucher_id = vid;
  if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  if v.status not in ('Draft','Returned') then raise exception 'এই ভাউচার আগেই সাবমিট হয়েছে।'; end if;
  if v.item_count < 1 then raise exception 'কমপক্ষে একটি খরচ যোগ করুন।'; end if;
  select * into e from employees where emp_id = v.emp_id;
  if found and e.pin <> '' then ok := pin = e.pin; else ok := _check_pin('user',pin); end if;
  if not ok and r = 'admin' then ok := _check_pin('admin',pin); end if;
  if not ok then raise exception 'ভুল পিন! সাবমিট হয়নি।'; end if;
  if sg !~ '^data:image/(png|jpeg);base64,' then raise exception 'সাবমিটের আগে সিগনেচার দিন।'; end if;
  if length(sg) > 48000 then raise exception 'সিগনেচার অনেক বড়, আবার ছোট করে দিন।'; end if;
  was_ret := v.status = 'Returned';
  update vouchers set user_sign=sg, status='Submitted', submitted_at=_now(), updated_at=_now(), submit_count=submit_count+1,
    voucher_no = case when voucher_no = '' then _next_voucher_no() else voucher_no end where voucher_id = vid;
  perform _log(vid, case when was_ret then 'Re-Submitted' else 'Submitted' end, v.emp_name, '');
  return _full_voucher(vid);
end $$;

create or replace function api_approve_voucher(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare vid text := args->>1; v vouchers; n int := case when args->>2 = '2' then 2 else 1 end; ap text; a1 text; a2 text; nt text := _str(args->>3);
begin
  perform _need(args->>0,'admin');
  perform pg_advisory_xact_lock(1);
  select * into v from vouchers where voucher_id = vid;
  if not found then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  if v.item_count < 1 then raise exception 'খালি ভাউচার অ্যাপ্রুভ করা যায় না।'; end if;
  if v.status in ('Draft','Returned') then raise exception 'সাবমিট হওয়া ভাউচারই অ্যাপ্রুভ করা যায়।'; end if;
  a1 := _gs('appr1_name','Ujjal Majumder'); a2 := _gs('appr2_name','Shamiron Halder');
  ap := case when n = 1 then a1 else a2 end;
  if (n = 1 and v.appr1_at <> '') or (n = 2 and v.appr2_at <> '') then raise exception '% আগেই অ্যাপ্রুভ করেছেন।', ap; end if;
  if n = 1 then v.appr1_at := _now(); else v.appr2_at := _now(); end if;
  update vouchers set appr1_at=v.appr1_at, appr2_at=v.appr2_at, status='Approved',
    approved_at = case when approved_at = '' then _now() else approved_at end,
    approved_by = concat_ws(', ', nullif(case when v.appr1_at <> '' then a1 else '' end,''), nullif(case when v.appr2_at <> '' then a2 else '' end,'')),
    admin_note = case when nt <> '' then nt else admin_note end, updated_at=_now() where voucher_id = vid;
  perform _log(vid,'Approved',ap,nt);
  return _full_voucher(vid);
end $$;

create or replace function api_return_voucher(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare vid text := args->>1;
begin
  perform _need(args->>0,'admin');
  perform pg_advisory_xact_lock(1);
  if not exists (select 1 from vouchers where voucher_id = vid) then raise exception 'ভাউচার পাওয়া যায়নি।'; end if;
  update vouchers set status='Returned', returned_at=_now(), approved_at='', approved_by='', appr1_at='', appr2_at='',
    admin_note=_str(args->>2), updated_at=_now() where voucher_id = vid;
  perform _log(vid,'Sent to User','Admin',_str(args->>2));
  return _full_voucher(vid);
end $$;

create or replace function api_assign_voucher_nos(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare id_ text; v vouchers; o jsonb := '{}'; no_ text;
begin
  perform _need(args->>0);
  perform pg_advisory_xact_lock(1);
  for id_ in select jsonb_array_elements_text(coalesce(args->1,'[]')) loop
    select * into v from vouchers where voucher_id = id_;
    if not found then continue; end if;
    no_ := v.voucher_no;
    if no_ = '' and v.status <> 'Draft' then
      no_ := _next_voucher_no();
      update vouchers set voucher_no = no_ where voucher_id = id_;
      perform _log(id_,'Voucher Generated','System',no_);
    end if;
    o := o || jsonb_build_object(id_, no_);
  end loop;
  return o;
end $$;

create or replace function api_list_vouchers(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r text := _need(args->>0); f jsonb := coalesce(args->1,'{}'); st text := coalesce(f->>'status','');
  mode text := coalesce(f->>'mode',''); inc boolean := coalesce((f->>'includeDrafts')::boolean,false);
  wi boolean := coalesce((f->>'withItems')::boolean,false); ws boolean := coalesce((f->>'withSign')::boolean,false);
  mk text := coalesce(f->>'year','') || '-' || lpad(coalesce(f->>'month',''),2,'0'); res jsonb;
begin
  select coalesce(jsonb_agg(
      _voucher_out(v)
      || case when wi then jsonb_build_object('items', coalesce((select jsonb_agg(_item_out(i) order by i.seq) from items i where i.voucher_id = v.voucher_id),'[]'::jsonb)) else '{}'::jsonb end
      || case when wi and ws then jsonb_build_object('userSign', v.user_sign) else '{}'::jsonb end
      order by v.date desc, v.emp_id asc), '[]'::jsonb) into res
  from vouchers v
  where (_str(f->>'empId') = '' or v.emp_id = _str(f->>'empId'))
    and (case when st <> '' and st <> 'All' then (case when st = 'Pending' then v.status = 'Submitted' else v.status = st end)
              else (inc or v.status <> 'Draft') end)
    and (mode <> 'date' or coalesce(f->>'date','') = '' or v.date = f->>'date')
    and (mode <> 'range' or ((coalesce(f->>'from','') = '' or v.date >= f->>'from') and (coalesce(f->>'to','') = '' or v.date <= f->>'to')))
    and (mode <> 'month' or coalesce(f->>'year','') = '' or coalesce(f->>'month','') = '' or left(v.date,7) = mk)
    and (mode <> 'year' or coalesce(f->>'year','') = '' or left(v.date,4) = f->>'year');
  return jsonb_build_object('role', r, 'vouchers', res);
end $$;

create or replace function api_get_dashboard(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare yr text := args->>1; mk text := (args->>1) || '-' || lpad(args->>2,2,'0'); td text := coalesce(nullif(_str(args->>3),''),_today());
  res jsonb;
begin
  perform _need(args->>0);
  select jsonb_build_object(
    'today', (select jsonb_build_object('date',td,'total',coalesce(sum(total) filter (where status<>'Draft'),0),'vouchers',count(*),
        'draft',count(*) filter (where status='Draft'),'draftAmt',coalesce(sum(total) filter (where status='Draft'),0),
        'submitted',count(*) filter (where status='Submitted'),'submittedAmt',coalesce(sum(total) filter (where status='Submitted'),0),
        'approved',count(*) filter (where status='Approved'),'approvedAmt',coalesce(sum(total) filter (where status='Approved'),0),
        'returned',count(*) filter (where status='Returned'),'returnedAmt',coalesce(sum(total) filter (where status='Returned'),0),
        'entries',coalesce(sum(item_count),0)) from vouchers where date = td),
    'month', (select jsonb_build_object('total',coalesce(sum(total) filter (where status<>'Draft'),0),
        'approved',coalesce(sum(total) filter (where status='Approved'),0),'approvedCnt',count(*) filter (where status='Approved'),
        'pending',coalesce(sum(total) filter (where status='Submitted'),0),'pendingCnt',count(*) filter (where status='Submitted'),
        'returned',coalesce(sum(total) filter (where status='Returned'),0),'returnedCnt',count(*) filter (where status='Returned'),
        'draft',coalesce(sum(total) filter (where status='Draft'),0),'draftCnt',count(*) filter (where status='Draft'),
        'vouchers',count(*) filter (where status<>'Draft'),'entries',coalesce(sum(item_count) filter (where status<>'Draft'),0),
        'employees',count(distinct emp_id) filter (where status<>'Draft')) from vouchers where left(date,7) = mk),
    'yearTotal', (select coalesce(sum(total),0) from vouchers where status<>'Draft' and left(date,4) = yr),
    'lifetimeTotal', (select coalesce(sum(total),0) from vouchers where status<>'Draft'),
    'pendingAll', (select count(*) from vouchers where status='Submitted'),
    'pendingAllAmt', (select coalesce(sum(total),0) from vouchers where status='Submitted'),
    'byEmployee', (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc),'[]'::jsonb) from (
        select jsonb_build_object('empId',emp_id,'name',max(emp_name),'total',sum(total),
          'approved',coalesce(sum(total) filter (where status='Approved'),0),'vouchers',count(*)) x
        from vouchers where left(date,7)=mk and status<>'Draft' group by emp_id) q),
    'byCategory', (select coalesce(jsonb_agg(x order by (x->>'total')::numeric desc),'[]'::jsonb) from (
        select jsonb_build_object('category',coalesce(nullif(i.category,''),'Others'),'total',sum(i.amount)) x
        from items i join vouchers v on v.voucher_id=i.voucher_id where left(v.date,7)=mk and v.status<>'Draft'
        group by coalesce(nullif(i.category,''),'Others')) q),
    'byDay', (select coalesce(jsonb_agg(jsonb_build_object('date',date,'total',t) order by date),'[]'::jsonb) from (
        select date, sum(total) t from vouchers where left(date,7)=mk and status<>'Draft' group by date) q),
    'recent', (select coalesce(jsonb_agg(_voucher_out(v) order by coalesce(nullif(v.submitted_at,''),v.updated_at) desc),'[]'::jsonb) from vouchers v
        where v.voucher_id in (select voucher_id from vouchers where status<>'Draft' order by coalesce(nullif(submitted_at,''),updated_at) desc limit 10))
  ) into res;
  return res;
end $$;

create or replace function api_save_employee(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare e jsonb := coalesce(args->1,'{}'); id_ text := _str(e->>'id'); nm text := _str(e->>'name'); orig text := _str(args->>2); ex employees;
begin
  perform _need(args->>0,'admin');
  perform pg_advisory_xact_lock(1);
  if id_ = '' or nm = '' then raise exception 'এমপ্লয়ি আইডি ও নাম দুটোই দিন।'; end if;
  if _str(e->>'pin') <> '' and _str(e->>'pin') !~ '^\d{4}$' then raise exception 'পিন ৪ ডিজিটের সংখ্যা হতে হবে।'; end if;
  if exists (select 1 from employees where lower(emp_id) = lower(id_) and emp_id <> orig) then raise exception 'এই আইডি আগে থেকেই আছে: %', id_; end if;
  select * into ex from employees where orig <> '' and emp_id = orig;
  if found then
    update employees set emp_id=id_, name=nm, designation=_str(e->>'designation'), department=_str(e->>'department'), mobile=_str(e->>'mobile'),
      pin=_str(e->>'pin'), active=coalesce((e->>'active')::boolean,true), updated_at=_now() where emp_id = orig;
  else
    insert into employees(emp_id,name,designation,department,mobile,pin,active,created_at,updated_at,sort_order)
      values (id_,nm,_str(e->>'designation'),_str(e->>'department'),_str(e->>'mobile'),_str(e->>'pin'),
        coalesce((e->>'active')::boolean,true),_now(),_now(),(select count(*)+1 from employees));
  end if;
  return _emps(true);
end $$;

create or replace function api_save_employee_order(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _need(args->>0,'admin');
  update employees e set sort_order = o.n from (select value as id, ordinality as n from jsonb_array_elements_text(coalesce(args->1,'[]')) with ordinality) o
    where e.emp_id = o.id and e.sort_order is distinct from o.n::int;
  return _emps(true);
end $$;

create or replace function api_delete_employee(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _need(args->>0,'admin');
  delete from employees where emp_id = _str(args->>1);
  return _emps(true);
end $$;

create or replace function api_save_settings(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare s jsonb := coalesce(args->1,'{}'); a jsonb; i int;
begin
  perform _need(args->>0,'admin');
  perform pg_advisory_xact_lock(1);
  if s ? 'companyName' then perform _ss('company_name',_str(s->>'companyName')); end if;
  if s ? 'tagline' then perform _ss('tagline',_str(s->>'tagline')); end if;
  if s ? 'companyAddress' then perform _ss('company_address',_str(s->>'companyAddress')); end if;
  if s ? 'voucherTitle' then perform _ss('voucher_title',_str(s->>'voucherTitle')); end if;
  if jsonb_typeof(s->'categories') = 'array' then
    perform _ss('categories',(select coalesce(jsonb_agg(trim(x)),'[]'::jsonb)::text from jsonb_array_elements_text(s->'categories') x where trim(x) <> '')); end if;
  if jsonb_typeof(s->'paymentModes') = 'array' then
    perform _ss('payment_modes',(select coalesce(jsonb_agg(trim(x)),'[]'::jsonb)::text from jsonb_array_elements_text(s->'paymentModes') x where trim(x) <> '')); end if;
  if coalesce(s->>'voucherPaper','') <> '' then perform _ss('voucher_paper', case when s->>'voucherPaper'='exact' then 'exact' else 'a4' end); end if;
  if coalesce(s->>'voucherMode','') <> '' then perform _ss('voucher_mode', case when s->>'voucherMode'='data' then 'data' else 'full' end); end if;
  if s ? 'signatures' then perform _ss('signature_config',(s->'signatures')::text); end if;
  if jsonb_typeof(s->'approvers') = 'array' then
    for i in 0..least(1, jsonb_array_length(s->'approvers')-1) loop
      a := s->'approvers'->i;
      if jsonb_typeof(a) <> 'object' then continue; end if;
      if a ? 'name' then perform _ss('appr'||(i+1)||'_name',_str(a->>'name')); end if;
      if a ? 'sign' then
        if length(coalesce(a->>'sign','')) > 48000 then raise exception 'সিগনেচার ছবি অনেক বড়। ৩০KB এর ছোট PNG দিন বা লিংক দিন।'; end if;
        perform _ss('appr'||(i+1)||'_sign',_str(a->>'sign'));
      end if;
    end loop;
  end if;
  if s ? 'logo' then
    if length(coalesce(s->>'logo','')) > 45000 then raise exception 'লোগো ফাইল অনেক বড়। ৩০KB এর ছোট ছবি দিন।'; end if;
    perform _ss('logo_data_url',coalesce(s->>'logo',''));
  end if;
  return _public_settings();
end $$;

create or replace function api_change_pin(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare kind text := args->>1; np text := _str(args->>3);
begin
  perform _need(args->>0,'admin');
  perform pg_advisory_xact_lock(1);
  if not _check_pin('admin',_str(args->>2)) then raise exception 'বর্তমান অ্যাডমিন পিন সঠিক নয়।'; end if;
  if kind = 'user' and np !~ '^\d{4}$' then raise exception 'ইউজার পিন ৪ ডিজিটের হতে হবে।'; end if;
  if kind = 'admin' and np !~ '^\d{4,8}$' then raise exception 'অ্যাডমিন পিন ৪-৮ ডিজিটের হতে হবে।'; end if;
  if kind = 'user' and _check_pin('admin',np) then raise exception 'ইউজার পিন ও অ্যাডমিন পিন একই হতে পারবে না।'; end if;
  if kind = 'admin' and _check_pin('user',np) then raise exception 'ইউজার পিন ও অ্যাডমিন পিন একই হতে পারবে না।'; end if;
  perform _ss(case when kind='admin' then 'admin_pin_hash' else 'user_pin_hash' end, _hash(np));
  if kind = 'admin' then perform _ss('admin_pin_len', length(np)::text); end if;
  perform _log('','PIN Changed','Admin',kind);
  return 'true'::jsonb;
end $$;

create or replace function api_get_activity_log(args jsonb) returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _need(args->>0);
  return coalesce((select jsonb_agg(jsonb_build_object('time',log_time,'voucherId',voucher_id,'action',action,'by',by_user,'note',note) order by id desc)
    from (select * from activity_log order by id desc limit coalesce(nullif(_num(args->>1),0),200)::int) l),'[]'::jsonb);
end $$;

-- ------------------------ PERMISSIONS ------------------------------
-- ভেতরের (_ দিয়ে শুরু) ফাংশন বন্ধ; শুধু api_* ফাংশন anon কল করতে পারবে
revoke execute on all functions in schema public from public, anon, authenticated;
do $$ declare f record; begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'api\_%' loop
    execute format('grant execute on function %s to anon, authenticated', f.sig);
  end loop;
end $$;

-- পিন রিসেট (দরকার হলে আলাদা করে চালান):
--   delete from settings where key in ('admin_pin_hash','user_pin_hash'); -- আবার 2019 / 2026
