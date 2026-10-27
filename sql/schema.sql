-- =====================================================================
-- Griya Nusa Residence — Progres Pembangunan Rumah
-- Skema database + aturan akses untuk Supabase (PostgreSQL).
--
-- CARA PAKAI: Supabase Dashboard > SQL Editor > New query > tempel seluruh
-- file ini > Run. Aman dijalankan ulang (idempotent).
--
-- Prinsip keamanan:
--  * Customer TIDAK punya akun. Customer membuka unit lewat fungsi
--    customer_progress(unit, kode) — kode akses disimpan sebagai hash bcrypt,
--    diperiksa di server, dan percobaan salah dibatasi.
--  * Data pribadi customer tidak disimpan di tabel yang bisa dibaca customer.
--  * Semua tabel memakai Row Level Security; admin harus login (Supabase Auth)
--    dan terdaftar di tabel public.admins.
--  * Foto disimpan di bucket PRIVAT 'progress-photos'. Customer hanya bisa
--    membaca foto unit yang sudah lolos verifikasi (izin berlaku 2 jam).
--  * Tidak ada password / service_role key di kode situs.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------------------------------------------------------------------
-- 1. Tabel
-- ---------------------------------------------------------------------

create table if not exists public.admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  email      text not null,
  role       text not null default 'editor' check (role in ('owner','editor')),
  created_at timestamptz not null default now()
);

create table if not exists public.stage_templates (
  pos    smallint primary key check (pos between 1 and 20),
  name   text not null,
  weight numeric(6,2) not null default 0 check (weight >= 0)
);

insert into public.stage_templates (pos, name, weight) values
  (1, 'Persiapan lahan',                              5),
  (2, 'Pekerjaan pondasi',                           15),
  (3, 'Pekerjaan struktur dan dinding',              20),
  (4, 'Pemasangan rangka dan penutup atap',          10),
  (5, 'Pekerjaan instalasi listrik dan plumbing',    12),
  (6, 'Pekerjaan plester, acian, dan lantai',        15),
  (7, 'Pemasangan pintu, jendela, serta finishing',  15),
  (8, 'Pemeriksaan akhir dan persiapan serah terima', 8)
on conflict (pos) do nothing;

create table if not exists public.units (
  id                  uuid primary key default gen_random_uuid(),
  unit_code           text not null unique check (unit_code ~ '^[A-Z]{1,3}-[0-9]{1,3}$'),
  block               text generated always as (split_part(unit_code, '-', 1)) stored,
  plot_no             text generated always as (split_part(unit_code, '-', 2)) stored,
  house_type          text check (char_length(house_type) <= 60),
  customer_ref        text check (char_length(customer_ref) <= 80),   -- catatan internal admin, TIDAK pernah dikirim ke customer
  update_date         date,                                            -- tanggal pembaruan yang ditampilkan ke customer
  team_notes          text check (char_length(team_notes) <= 2000),
  next_estimate       text check (char_length(next_estimate) <= 300),
  next_estimate_date  date,
  customer_visible    boolean not null default true,
  content_changed_at  timestamptz not null default now(),
  last_published_at   timestamptz,
  code_set_at         timestamptz,                                     -- kapan kode akses terakhir dibuat (hash-nya tersimpan terpisah)
  created_by          uuid default auth.uid(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- (aman untuk instalasi lama) kolom yang ditambahkan belakangan
alter table public.units add column if not exists code_set_at timestamptz;

-- Hash kode akses dipisah agar tidak pernah ikut terbaca lewat API tabel.
create table if not exists public.unit_secrets (
  unit_id          uuid primary key references public.units(id) on delete cascade,
  access_code_hash text not null,
  set_at           timestamptz not null default now()
);

create table if not exists public.unit_stages (
  unit_id uuid not null references public.units(id) on delete cascade,
  pos     smallint not null check (pos between 1 and 20),
  name    text not null check (char_length(name) between 1 and 120),
  weight  numeric(6,2) not null default 0 check (weight >= 0),
  status  text not null default 'belum' check (status in ('belum','proses','selesai')),
  pct     smallint not null default 0 check (pct between 0 and 100),
  primary key (unit_id, pos)
);

create table if not exists public.progress_photos (
  id                 uuid primary key default gen_random_uuid(),
  unit_id            uuid not null references public.units(id) on delete cascade,
  stage_pos          smallint,
  taken_on           date not null default current_date,
  caption            text not null check (char_length(caption) between 1 and 200),
  notes              text check (char_length(notes) <= 1000),
  storage_path       text not null unique,
  uploaded_by        uuid default auth.uid(),
  uploaded_by_email  text default (auth.jwt() ->> 'email'),
  created_at         timestamptz not null default now()
);
create index if not exists progress_photos_unit_idx on public.progress_photos (unit_id, taken_on, created_at);

-- Pembaruan yang SUDAH DITERBITKAN (snapshot). Customer hanya melihat ini.
create table if not exists public.unit_publications (
  id                 uuid primary key default gen_random_uuid(),
  unit_id            uuid not null references public.units(id) on delete cascade,
  version            integer not null,
  published_at       timestamptz not null default now(),
  published_by       uuid,
  published_by_email text,
  update_date        date not null,
  percent            numeric(5,1) not null,
  status_label       text not null,
  stages             jsonb not null,
  team_notes         text,
  next_estimate      text,
  next_estimate_date date,
  photos             jsonb not null default '[]'::jsonb,
  change_note        text,
  unique (unit_id, version)
);

create table if not exists public.audit_log (
  id          bigint generated always as identity primary key,
  at          timestamptz not null default now(),
  actor_id    uuid,
  actor_email text,
  unit_id     uuid,
  unit_code   text,
  action      text not null,
  summary     text not null,
  detail      jsonb
);
create index if not exists audit_log_unit_idx on public.audit_log (unit_id, at desc);

-- Pembatasan percobaan kode salah + izin baca foto sementara (tanpa kebijakan = tertutup)
create table if not exists public.access_attempts (
  id        bigint generated always as identity primary key,
  at        timestamptz not null default now(),
  unit_code text,
  ip        text
);
create index if not exists access_attempts_idx on public.access_attempts (at);

create table if not exists public.photo_grants (
  path       text primary key,
  expires_at timestamptz not null
);

-- ---------------------------------------------------------------------
-- 2. Fungsi bantu
-- ---------------------------------------------------------------------

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

create or replace function public.is_owner() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid() and role = 'owner');
$$;

create or replace function public.has_photo_grant(p_path text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.photo_grants where path = p_path and expires_at > now());
$$;

-- "Blok D9", "d-9", "D 09", "blok D no. 9" -> 'D-9'; selain itu NULL
create or replace function public.normalize_unit_code(p text) returns text
language plpgsql immutable as $$
declare s text; m text[];
begin
  if p is null then return null; end if;
  s := upper(p);
  s := regexp_replace(s, '\m(BLOK|BLOCK|KAVLING|NOMOR|NO)\M', '', 'g');
  s := regexp_replace(s, '[^A-Z0-9]', '', 'g');
  m := regexp_match(s, '^([A-Z]{1,3})0*([0-9]{1,3})$');
  if m is null then return null; end if;
  return m[1] || '-' || m[2];
end $$;

create or replace function public.unit_percent(p_unit uuid) returns numeric
language sql stable security definer set search_path = public as $$
  select case when coalesce(sum(weight), 0) = 0 then 0
              else round(sum(weight * pct) / sum(weight), 1) end
  from public.unit_stages where unit_id = p_unit;
$$;

create or replace function public.unit_status_label(p_unit uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare n int; n_done int; n_proc int; cur text; nxt text;
begin
  select count(*), count(*) filter (where status = 'selesai'), count(*) filter (where status = 'proses')
    into n, n_done, n_proc from public.unit_stages where unit_id = p_unit;
  if n = 0 or (n_done = 0 and n_proc = 0) then return 'Belum dimulai'; end if;
  if n_done = n then return 'Seluruh tahap selesai'; end if;
  if n_proc > 0 then
    select name into cur from public.unit_stages where unit_id = p_unit and status = 'proses' order by pos limit 1;
    return 'Sedang dikerjakan: ' || cur || case when n_proc > 1 then ' (+' || (n_proc - 1) || ' tahap lain)' else '' end;
  end if;
  select name into nxt from public.unit_stages where unit_id = p_unit and status = 'belum' order by pos limit 1;
  return 'Menunggu tahap berikutnya: ' || nxt;
end $$;

-- ---------------------------------------------------------------------
-- 3. Trigger: normalisasi tahap, template tahap, penanda perubahan, riwayat
-- ---------------------------------------------------------------------

create or replace function public.trg_stage_normalize() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and auth.uid() is not null and not public.is_owner()
     and (new.name is distinct from old.name or new.weight is distinct from old.weight
          or new.pos is distinct from old.pos or new.unit_id is distinct from old.unit_id) then
    raise exception 'Hanya pemilik (owner) yang boleh mengubah nama tahap atau bobot.' using errcode = '42501';
  end if;
  if new.status = 'belum' then new.pct := 0;
  elsif new.status = 'selesai' then new.pct := 100;
  else new.pct := least(greatest(new.pct, 0), 99);
  end if;
  return new;
end $$;

drop trigger if exists stage_normalize on public.unit_stages;
create trigger stage_normalize before insert or update on public.unit_stages
  for each row execute function public.trg_stage_normalize();

create or replace function public.trg_unit_after_insert() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.unit_stages (unit_id, pos, name, weight)
    select new.id, pos, name, weight from public.stage_templates order by pos;
  return null;
end $$;

drop trigger if exists unit_after_insert on public.units;
create trigger unit_after_insert after insert on public.units
  for each row execute function public.trg_unit_after_insert();

create or replace function public.trg_units_touch() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if (new.house_type, new.update_date, new.team_notes, new.next_estimate, new.next_estimate_date, new.customer_visible)
     is distinct from (old.house_type, old.update_date, old.team_notes, old.next_estimate, old.next_estimate_date, old.customer_visible) then
    new.content_changed_at := now();
  end if;
  return new;
end $$;

drop trigger if exists units_touch on public.units;
create trigger units_touch before update on public.units
  for each row execute function public.trg_units_touch();

-- tulis riwayat (dipanggil oleh trigger; berjalan sebagai pemilik fungsi)
create or replace function public.log_change(p_unit uuid, p_code text, p_action text, p_summary text, p_detail jsonb default null)
returns void language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (actor_id, actor_email, unit_id, unit_code, action, summary, detail)
  values (auth.uid(), coalesce(auth.jwt() ->> 'email', 'sistem'), p_unit, p_code, p_action, p_summary, p_detail);
end $$;

create or replace function public.mark_unit_changed(p_unit uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  update public.units set content_changed_at = now() where id = p_unit;
end $$;

create or replace function public.stage_status_text(s text) returns text
language sql immutable as $$
  select case s when 'belum' then 'Belum dimulai' when 'proses' then 'Sedang dikerjakan' when 'selesai' then 'Selesai' else s end;
$$;

create or replace function public.trg_units_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare ch text[] := '{}';
begin
  if tg_op = 'INSERT' then
    perform public.log_change(new.id, new.unit_code, 'unit_dibuat', 'Unit ' || new.unit_code || ' dibuat');
  elsif tg_op = 'DELETE' then
    perform public.log_change(null, old.unit_code, 'unit_dihapus', 'Unit ' || old.unit_code || ' dihapus');
  else
    if new.house_type is distinct from old.house_type then ch := array_append(ch, ('tipe rumah')::text); end if;
    if new.update_date is distinct from old.update_date then ch := array_append(ch, ('tanggal pembaruan')::text); end if;
    if new.team_notes is distinct from old.team_notes then ch := array_append(ch, ('catatan tim')::text); end if;
    if new.next_estimate is distinct from old.next_estimate or new.next_estimate_date is distinct from old.next_estimate_date then ch := array_append(ch, ('estimasi tahap berikutnya')::text); end if;
    if new.customer_visible is distinct from old.customer_visible then ch := array_append(ch, ((case when new.customer_visible then 'tampil ke customer: ya' else 'tampil ke customer: tidak' end))::text); end if;
    if new.customer_ref is distinct from old.customer_ref then ch := array_append(ch, ('catatan internal')::text); end if;
    if new.unit_code is distinct from old.unit_code then ch := array_append(ch, (('kode unit ' || old.unit_code || ' → ' || new.unit_code))::text); end if;
    if array_length(ch, 1) > 0 then
      perform public.log_change(new.id, new.unit_code, 'unit_diubah', 'Mengubah ' || array_to_string(ch, ', '));
    end if;
  end if;
  return null;
end $$;

drop trigger if exists units_audit on public.units;
create trigger units_audit after insert or update or delete on public.units
  for each row execute function public.trg_units_audit();

create or replace function public.trg_stages_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare code text; txt text;
begin
  if tg_op = 'DELETE' then
    select unit_code into code from public.units where id = old.unit_id;
    if code is not null then   -- bukan akibat penghapusan seluruh unit
      perform public.log_change(old.unit_id, code, 'tahap_dihapus', 'Tahap ' || old.pos || ' «' || old.name || '» dihapus');
      perform public.mark_unit_changed(old.unit_id);
    end if;
    return null;
  end if;
  select unit_code into code from public.units where id = new.unit_id;
  if tg_op = 'INSERT' then
    -- salinan otomatis dari template tidak dicatat satu per satu; hanya penambahan manual
    if auth.uid() is not null and pg_trigger_depth() = 1 then
      perform public.log_change(new.unit_id, code, 'tahap_ditambah', 'Tahap ' || new.pos || ' «' || new.name || '» ditambahkan (bobot ' || new.weight || ')');
      perform public.mark_unit_changed(new.unit_id);
    end if;
    return null;
  end if;
  if new.status is distinct from old.status or new.pct is distinct from old.pct then
    txt := 'Tahap ' || new.pos || ' «' || new.name || '»: ' || public.stage_status_text(old.status)
        || case when old.status = 'proses' then ' (' || old.pct || '%)' else '' end
        || ' → ' || public.stage_status_text(new.status)
        || case when new.status = 'proses' then ' (' || new.pct || '%)' else '' end;
    perform public.log_change(new.unit_id, code, 'tahap_status', txt,
      jsonb_build_object('pos', new.pos, 'dari', old.status, 'ke', new.status, 'pct', new.pct));
    perform public.mark_unit_changed(new.unit_id);
  end if;
  if new.weight is distinct from old.weight then
    perform public.log_change(new.unit_id, code, 'tahap_bobot', 'Bobot tahap ' || new.pos || ' «' || new.name || '»: ' || old.weight || ' → ' || new.weight);
    perform public.mark_unit_changed(new.unit_id);
  end if;
  if new.name is distinct from old.name then
    perform public.log_change(new.unit_id, code, 'tahap_nama', 'Nama tahap ' || new.pos || ': «' || old.name || '» → «' || new.name || '»');
    perform public.mark_unit_changed(new.unit_id);
  end if;
  return null;
end $$;

drop trigger if exists stages_audit on public.unit_stages;
create trigger stages_audit after insert or update or delete on public.unit_stages
  for each row execute function public.trg_stages_audit();

create or replace function public.trg_photos_audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare code text;
begin
  if tg_op = 'DELETE' then
    select unit_code into code from public.units where id = old.unit_id;
    if code is not null then
      perform public.log_change(old.unit_id, code, 'foto_dihapus', 'Foto dihapus: «' || old.caption || '»');
      perform public.mark_unit_changed(old.unit_id);
    end if;
    return null;
  end if;
  select unit_code into code from public.units where id = new.unit_id;
  if tg_op = 'INSERT' then
    perform public.log_change(new.unit_id, code, 'foto_diunggah',
      'Foto diunggah: «' || new.caption || '»' || case when new.stage_pos is not null then ' (tahap ' || new.stage_pos || ')' else '' end,
      jsonb_build_object('photo_id', new.id, 'taken_on', new.taken_on));
  else
    perform public.log_change(new.unit_id, code, 'foto_diubah', 'Keterangan foto diubah: «' || new.caption || '»');
  end if;
  perform public.mark_unit_changed(new.unit_id);
  return null;
end $$;

drop trigger if exists photos_audit on public.progress_photos;
create trigger photos_audit after insert or update or delete on public.progress_photos
  for each row execute function public.trg_photos_audit();

-- Isi uploaded_by dari sesi login, apa pun yang dikirim klien
create or replace function public.trg_photos_owner() returns trigger
language plpgsql as $$
begin
  if auth.uid() is not null then
    new.uploaded_by := auth.uid();
    new.uploaded_by_email := auth.jwt() ->> 'email';
  end if;
  return new;
end $$;

drop trigger if exists photos_owner on public.progress_photos;
create trigger photos_owner before insert on public.progress_photos
  for each row execute function public.trg_photos_owner();

create or replace function public.trg_template_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.log_change(null, null, 'template_tahap',
    'Template tahap ' || coalesce(new.pos, old.pos) || ' diubah' || case when tg_op = 'DELETE' then ' (dihapus)' else ': «' || new.name || '», bobot ' || new.weight end
    || ' (berlaku untuk unit baru)');
  return null;
end $$;

drop trigger if exists template_audit on public.stage_templates;
create trigger template_audit after insert or update or delete on public.stage_templates
  for each row execute function public.trg_template_audit();

create or replace function public.trg_admins_audit() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.log_change(null, null, 'admin',
    case tg_op when 'INSERT' then 'Admin ditambahkan: ' || new.email || ' (' || new.role || ')'
               when 'DELETE' then 'Admin dihapus: ' || old.email
               else 'Admin diubah: ' || new.email || ' (' || new.role || ')' end);
  return null;
end $$;

drop trigger if exists admins_audit on public.admins;
create trigger admins_audit after insert or update or delete on public.admins
  for each row execute function public.trg_admins_audit();

-- ---------------------------------------------------------------------
-- 4. Fungsi yang dipanggil aplikasi
-- ---------------------------------------------------------------------

-- 4a. ADMIN: buat kode akses baru untuk satu unit. Kode asli hanya dikembalikan sekali.
create or replace function public.reset_access_code(p_unit uuid) returns text
language plpgsql security definer set search_path = public, extensions as $$
declare alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
        b bytea; raw text := ''; i int; code text; ucode text;
begin
  if not public.is_admin() then raise exception 'Tidak berwenang.' using errcode = '42501'; end if;
  select unit_code into ucode from public.units where id = p_unit;
  if ucode is null then raise exception 'Unit tidak ditemukan.'; end if;
  b := gen_random_bytes(10);
  for i in 0..9 loop
    raw := raw || substr(alphabet, (get_byte(b, i) % 32) + 1, 1);
  end loop;
  code := substr(raw, 1, 5) || '-' || substr(raw, 6, 5);
  insert into public.unit_secrets (unit_id, access_code_hash, set_at)
    values (p_unit, crypt(raw, gen_salt('bf', 8)), now())
  on conflict (unit_id) do update set access_code_hash = excluded.access_code_hash, set_at = now();
  update public.units set code_set_at = now() where id = p_unit;
  perform public.log_change(p_unit, ucode, 'kode_akses', 'Kode akses baru dibuat (kode lama tidak berlaku lagi)');
  return code;
end $$;

-- 4b. ADMIN: terbitkan keadaan unit saat ini agar terlihat oleh customer
create or replace function public.publish_unit(p_unit uuid, p_note text default null) returns integer
language plpgsql security definer set search_path = public as $$
declare u public.units%rowtype; v_ver int; v_stg jsonb; v_pho jsonb; v_pct numeric; v_lbl text; v_d date;
begin
  if not public.is_admin() then raise exception 'Tidak berwenang.' using errcode = '42501'; end if;
  select * into u from public.units where id = p_unit for update;
  if not found then raise exception 'Unit tidak ditemukan.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('pos', s.pos, 'name', s.name, 'weight', s.weight, 'status', s.status, 'pct', s.pct) order by s.pos), '[]'::jsonb)
    into v_stg from public.unit_stages s where s.unit_id = p_unit;
  if v_stg = '[]'::jsonb then raise exception 'Unit belum punya tahapan pekerjaan.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', f.id, 'path', f.storage_path, 'taken_on', f.taken_on, 'stage_pos', f.stage_pos, 'caption', f.caption, 'notes', f.notes) order by f.taken_on, f.created_at), '[]'::jsonb)
    into v_pho from public.progress_photos f where f.unit_id = p_unit;
  v_pct := public.unit_percent(p_unit);
  v_lbl := public.unit_status_label(p_unit);
  v_d := coalesce(u.update_date, current_date);
  select coalesce(max(version), 0) + 1 into v_ver from public.unit_publications where unit_id = p_unit;
  insert into public.unit_publications
    (unit_id, version, published_by, published_by_email, update_date, percent, status_label, stages, team_notes, next_estimate, next_estimate_date, photos, change_note)
  values (p_unit, v_ver, auth.uid(), auth.jwt() ->> 'email', v_d, v_pct, v_lbl, v_stg, u.team_notes, u.next_estimate, u.next_estimate_date, v_pho, nullif(btrim(p_note), ''));
  update public.units set last_published_at = now() where id = p_unit;
  perform public.log_change(p_unit, u.unit_code, 'terbit', 'Pembaruan #' || v_ver || ' diterbitkan ke customer (' || v_pct || '%)'
          || case when nullif(btrim(p_note), '') is not null then ' — ' || btrim(p_note) else '' end);
  return v_ver;
end $$;

-- 4c. CUSTOMER: buka progres unit dengan nomor unit + kode akses
create or replace function public.customer_progress(p_unit text, p_code text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_ucode text; v_ncode text; u public.units%rowtype; v_hash text; v_ok boolean := false; v_ip text; v_hdr text;
  v_fail_unit int; v_fail_ip int; pub public.unit_publications%rowtype; v_hist jsonb; v_photos jsonb;
begin
  v_ucode := public.normalize_unit_code(p_unit);
  v_ncode := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  v_hdr := nullif(current_setting('request.headers', true), '');
  begin
    v_ip := coalesce(nullif(btrim(split_part(coalesce(v_hdr::json ->> 'x-forwarded-for', ''), ',', 1)), ''), 'tidak-diketahui');
  exception when others then v_ip := 'tidak-diketahui';
  end;

  delete from public.access_attempts a where a.at < now() - interval '1 day';
  delete from public.photo_grants g where g.expires_at < now();

  select count(*) into v_fail_ip   from public.access_attempts a where a.ip = v_ip and a.at > now() - interval '15 minutes';
  select count(*) into v_fail_unit from public.access_attempts a where a.unit_code = v_ucode and a.at > now() - interval '15 minutes';
  if v_fail_ip >= 15 or (v_ucode is not null and v_fail_unit >= 8) then
    return jsonb_build_object('ok', false, 'error', 'terlalu_banyak_percobaan');
  end if;

  if v_ucode is not null then
    select * into u from public.units x where x.unit_code = v_ucode and x.customer_visible;
    if found then select s.access_code_hash into v_hash from public.unit_secrets s where s.unit_id = u.id; end if;
  end if;
  -- selalu jalankan satu perbandingan hash agar waktu respons tidak membocorkan keberadaan unit
  v_ok := (crypt(v_ncode, coalesce(v_hash, '$2a$08$abcdefghijklmnopqrstuuABCDEFGHIJKLMNOPQRSTUVWXYZ01234')) = coalesce(v_hash, '#'))
          and v_hash is not null and length(v_ncode) >= 6;
  if not v_ok then
    insert into public.access_attempts (unit_code, ip) values (v_ucode, v_ip);
    return jsonb_build_object('ok', false, 'error', 'tidak_cocok');
  end if;

  select * into pub from public.unit_publications p where p.unit_id = u.id order by p.version desc limit 1;
  if not found then
    return jsonb_build_object('ok', true, 'published', false, 'project', 'Griya Nusa Residence',
      'unit', jsonb_build_object('code', u.unit_code, 'block', u.block, 'plot', u.plot_no, 'house_type', u.house_type));
  end if;

  -- hanya foto yang masih ada; beri izin baca 2 jam
  select coalesce(jsonb_agg(t.e order by (t.e ->> 'taken_on'), t.ord), '[]'::jsonb) into v_photos
  from jsonb_array_elements(pub.photos) with ordinality as t(e, ord)
  where exists (select 1 from public.progress_photos pp where pp.id = (t.e ->> 'id')::uuid);

  insert into public.photo_grants (path, expires_at)
    select f ->> 'path', now() + interval '2 hours' from jsonb_array_elements(v_photos) f
  on conflict (path) do update set expires_at = excluded.expires_at;

  select coalesce(jsonb_agg(jsonb_build_object('version', h.version, 'published_at', h.published_at, 'update_date', h.update_date,
           'percent', h.percent, 'status', h.status_label, 'note', h.change_note) order by h.version desc), '[]'::jsonb) into v_hist
  from (select * from public.unit_publications q where q.unit_id = u.id order by q.version desc limit 30) h;

  return jsonb_build_object(
    'ok', true, 'published', true, 'project', 'Griya Nusa Residence',
    'unit', jsonb_build_object('code', u.unit_code, 'block', u.block, 'plot', u.plot_no, 'house_type', u.house_type),
    'percent', pub.percent, 'status', pub.status_label, 'update_date', pub.update_date, 'published_at', pub.published_at,
    'version', pub.version,
    'stages', (select coalesce(jsonb_agg(jsonb_build_object('pos', s -> 'pos', 'name', s -> 'name', 'status', s -> 'status', 'pct', s -> 'pct', 'weight', s -> 'weight') order by (s ->> 'pos')::int), '[]'::jsonb) from jsonb_array_elements(pub.stages) s),
    'team_notes', pub.team_notes, 'next_estimate', pub.next_estimate, 'next_estimate_date', pub.next_estimate_date,
    'photos', (select coalesce(jsonb_agg(jsonb_build_object('id', p -> 'id', 'path', p -> 'path', 'taken_on', p -> 'taken_on', 'stage_pos', p -> 'stage_pos', 'caption', p -> 'caption', 'notes', p -> 'notes')), '[]'::jsonb) from jsonb_array_elements(v_photos) p),
    'history', v_hist);
end $$;

-- ---------------------------------------------------------------------
-- 5. Hak akses tabel + Row Level Security
-- ---------------------------------------------------------------------

alter table public.admins            enable row level security;
alter table public.stage_templates   enable row level security;
alter table public.units             enable row level security;
alter table public.unit_secrets      enable row level security;
alter table public.unit_stages       enable row level security;
alter table public.progress_photos   enable row level security;
alter table public.unit_publications enable row level security;
alter table public.audit_log         enable row level security;
alter table public.access_attempts   enable row level security;
alter table public.photo_grants      enable row level security;

revoke all on public.admins, public.stage_templates, public.units, public.unit_secrets, public.unit_stages,
              public.progress_photos, public.unit_publications, public.audit_log, public.access_attempts,
              public.photo_grants from anon, authenticated;

grant select, insert, update, delete on public.admins          to authenticated;
grant select, insert, update, delete on public.stage_templates to authenticated;
grant select, insert, update, delete on public.units           to authenticated;
grant select, insert, update, delete on public.unit_stages     to authenticated;
grant select, insert, update, delete on public.progress_photos to authenticated;
grant select                         on public.unit_publications to authenticated;
grant select                         on public.audit_log       to authenticated;
-- unit_secrets, access_attempts, photo_grants: tidak ada hak untuk anon/authenticated

drop policy if exists admins_read   on public.admins;
drop policy if exists admins_write  on public.admins;
create policy admins_read  on public.admins for select to authenticated using (public.is_admin());
create policy admins_write on public.admins for all    to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists tmpl_read  on public.stage_templates;
drop policy if exists tmpl_write on public.stage_templates;
create policy tmpl_read  on public.stage_templates for select to authenticated using (public.is_admin());
create policy tmpl_write on public.stage_templates for all    to authenticated using (public.is_owner()) with check (public.is_owner());

drop policy if exists units_read   on public.units;
drop policy if exists units_insert on public.units;
drop policy if exists units_update on public.units;
drop policy if exists units_delete on public.units;
create policy units_read   on public.units for select to authenticated using (public.is_admin());
create policy units_insert on public.units for insert to authenticated with check (public.is_admin());
create policy units_update on public.units for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy units_delete on public.units for delete to authenticated using (public.is_owner());

drop policy if exists stages_read   on public.unit_stages;
drop policy if exists stages_update on public.unit_stages;
drop policy if exists stages_insert on public.unit_stages;
drop policy if exists stages_delete on public.unit_stages;
create policy stages_read   on public.unit_stages for select to authenticated using (public.is_admin());
create policy stages_update on public.unit_stages for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy stages_insert on public.unit_stages for insert to authenticated with check (public.is_owner());
create policy stages_delete on public.unit_stages for delete to authenticated using (public.is_owner());

drop policy if exists photos_read   on public.progress_photos;
drop policy if exists photos_insert on public.progress_photos;
drop policy if exists photos_update on public.progress_photos;
drop policy if exists photos_delete on public.progress_photos;
create policy photos_read   on public.progress_photos for select to authenticated using (public.is_admin());
create policy photos_insert on public.progress_photos for insert to authenticated with check (public.is_admin());
create policy photos_update on public.progress_photos for update to authenticated using (public.is_admin() and (public.is_owner() or uploaded_by = auth.uid())) with check (public.is_admin());
create policy photos_delete on public.progress_photos for delete to authenticated using (public.is_owner() or (public.is_admin() and uploaded_by = auth.uid()));

drop policy if exists pubs_read on public.unit_publications;
create policy pubs_read on public.unit_publications for select to authenticated using (public.is_admin());

drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated using (public.is_admin());

-- Fungsi: tutup untuk publik, buka hanya sesuai kebutuhan
revoke all on function public.reset_access_code(uuid)         from public, anon, authenticated;
revoke all on function public.publish_unit(uuid, text)        from public, anon, authenticated;
revoke all on function public.customer_progress(text, text)   from public, anon, authenticated;
revoke all on function public.log_change(uuid, text, text, text, jsonb) from public, anon, authenticated;
revoke all on function public.mark_unit_changed(uuid)         from public, anon, authenticated;
revoke all on function public.unit_percent(uuid)              from public, anon, authenticated;
revoke all on function public.unit_status_label(uuid)         from public, anon, authenticated;
revoke all on function public.is_admin()                      from public, anon, authenticated;
revoke all on function public.is_owner()                      from public, anon, authenticated;
revoke all on function public.has_photo_grant(text)           from public, anon, authenticated;

grant execute on function public.reset_access_code(uuid)       to authenticated;
grant execute on function public.publish_unit(uuid, text)      to authenticated;
grant execute on function public.customer_progress(text, text) to anon, authenticated;
grant execute on function public.unit_percent(uuid)            to authenticated;
grant execute on function public.unit_status_label(uuid)       to authenticated;
grant execute on function public.is_admin()                    to anon, authenticated;
grant execute on function public.is_owner()                    to anon, authenticated;
grant execute on function public.has_photo_grant(text)         to anon, authenticated;

-- ---------------------------------------------------------------------
-- 6. Penyimpanan foto (bucket PRIVAT) + aturan akses
-- ---------------------------------------------------------------------

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('progress-photos', 'progress-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do update set public = false, file_size_limit = 5242880,
                               allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp'];

drop policy if exists "gnr foto admin baca"    on storage.objects;
drop policy if exists "gnr foto admin unggah"  on storage.objects;
drop policy if exists "gnr foto admin hapus"   on storage.objects;
drop policy if exists "gnr foto customer baca" on storage.objects;

create policy "gnr foto admin baca"   on storage.objects for select to authenticated
  using (bucket_id = 'progress-photos' and public.is_admin());
create policy "gnr foto admin unggah" on storage.objects for insert to authenticated
  with check (bucket_id = 'progress-photos' and public.is_admin());
-- objek hanya boleh dihapus setelah barisnya di progress_photos lolos aturan penghapusan di atas
create policy "gnr foto admin hapus"  on storage.objects for delete to authenticated
  using (bucket_id = 'progress-photos' and public.is_admin()
         and not exists (select 1 from public.progress_photos p where p.storage_path = name));
create policy "gnr foto customer baca" on storage.objects for select to anon
  using (bucket_id = 'progress-photos' and public.has_photo_grant(name));

-- ---------------------------------------------------------------------
-- 7. SETELAH SQL INI: buat akun admin pertama
--   a) Dashboard > Authentication > Users > Add user (email + password), centang Auto Confirm.
--   b) Jalankan (ganti email-nya):
--        insert into public.admins (user_id, email, role)
--        select id, email, 'owner' from auth.users where email = 'email-admin@contoh.com';
--   c) Matikan pendaftaran publik: Authentication > Sign In / Providers > "Allow new users to sign up" = OFF.
-- ---------------------------------------------------------------------
