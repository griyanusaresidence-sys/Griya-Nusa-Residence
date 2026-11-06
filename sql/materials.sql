-- =====================================================================
-- GRIYA NUSA RESIDENCE: Spesifikasi Bahan Bangunan (tabel material + foto)
-- Jalankan SETELAH schema.sql (butuh tabel admins dan fungsi is_admin()).
-- Aman dijalankan ulang. Isi awal hanya berupa daftar nama material dan keterangan fungsi umum.
-- Merek, ukuran, dan spesifikasi teknis TIDAK diisi di sini: isi lewat Dashboard Admin > Spesifikasi Material.
-- =====================================================================

create table if not exists public.materials (
  id            uuid primary key default gen_random_uuid(),
  category      text not null check (category in ('A','B','C','D','E','F','G')),
  name          text not null check (char_length(btrim(name)) between 1 and 120),
  brand         text check (brand is null or char_length(brand) <= 120),
  spec          text check (spec is null or char_length(spec) <= 400),
  function_desc text check (function_desc is null or char_length(function_desc) <= 500),
  quality_note  text check (quality_note is null or char_length(quality_note) <= 500),
  detail        text check (detail is null or char_length(detail) <= 2000),
  photo_path    text check (photo_path is null or photo_path ~ '^[A-Za-z0-9_-]{1,80}\.jpg$'),
  sort_order    integer not null default 0,
  updated_at    timestamptz not null default now(),
  updated_by    uuid
);
-- Asal foto (jujur ke pengunjung): 'proyek' = dokumentasi material proyek; 'produsen' = foto produk dari produsen/merek;
-- 'referensi' = foto referensi sejenis. Foto selain 'proyek' diberi label di halaman publik.
alter table public.materials add column if not exists photo_source text;
alter table public.materials drop constraint if exists materials_photo_source_chk;
alter table public.materials add constraint materials_photo_source_chk check (photo_source is null or photo_source in ('proyek','produsen','referensi'));
-- Foto tambahan per material (galeri di panel detail). photo_path tetap foto utama/kartu carousel.
create or replace function public.photo_paths_ok(p text[]) returns boolean
language sql immutable as $$
  select coalesce(cardinality(p), 0) <= 8 and not exists (select 1 from unnest(p) x where x !~ '^[A-Za-z0-9_-]{1,80}\.jpg$')
$$;
alter table public.materials add column if not exists gallery text[] not null default '{}';
alter table public.materials drop constraint if exists materials_gallery_chk;
alter table public.materials add constraint materials_gallery_chk check (public.photo_paths_ok(gallery));
create index if not exists materials_cat_sort on public.materials (category, sort_order);

create or replace function public.trg_materials_touch() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
drop trigger if exists materials_touch on public.materials;
create trigger materials_touch before insert or update on public.materials
  for each row execute function public.trg_materials_touch();

alter table public.materials enable row level security;
grant select on public.materials to anon, authenticated;
grant insert, update, delete on public.materials to authenticated;

drop policy if exists materials_read   on public.materials;
drop policy if exists materials_insert on public.materials;
drop policy if exists materials_update on public.materials;
drop policy if exists materials_delete on public.materials;
-- isi katalog material bersifat publik (tanpa data pribadi); hanya admin yang boleh mengubah
create policy materials_read   on public.materials for select to anon, authenticated using (true);
create policy materials_insert on public.materials for insert to authenticated with check (public.is_admin());
create policy materials_update on public.materials for update to authenticated using (public.is_admin()) with check (public.is_admin());
create policy materials_delete on public.materials for delete to authenticated using (public.is_admin());

-- Penyimpanan foto material: bucket PUBLIK (foto katalog memang untuk dilihat umum), hanya admin yang bisa mengubah.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('material-photos', 'material-photos', true, 2097152, array['image/jpeg'])
on conflict (id) do update set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/jpeg'];

drop policy if exists "gnr material baca"    on storage.objects;
drop policy if exists "gnr material unggah"  on storage.objects;
drop policy if exists "gnr material ubah"    on storage.objects;
drop policy if exists "gnr material hapus"   on storage.objects;
create policy "gnr material baca"   on storage.objects for select to anon, authenticated
  using (bucket_id = 'material-photos');
create policy "gnr material unggah" on storage.objects for insert to authenticated
  with check (bucket_id = 'material-photos' and public.is_admin());
create policy "gnr material ubah"   on storage.objects for update to authenticated
  using (bucket_id = 'material-photos' and public.is_admin()) with check (bucket_id = 'material-photos' and public.is_admin());
create policy "gnr material hapus"  on storage.objects for delete to authenticated
  using (bucket_id = 'material-photos' and public.is_admin());

-- Isi awal (hanya jika tabel masih kosong)
insert into public.materials (category, name, brand, spec, function_desc, sort_order)
select v.category, v.name, nullif(v.brand, ''), nullif(v.spec, ''), v.function_desc, v.sort_order
from (values
  ('A','Batu Gunung','','','Bahan pasangan pondasi yang menyalurkan beban bangunan ke tanah.',10),
  ('A','Pasir Palu','','','Bahan campuran beton dan adukan untuk pekerjaan pondasi dan struktur.',20),
  ('A','Batu Split Palu','','','Agregat kasar campuran beton untuk pekerjaan struktur.',30),
  ('A','Semen','','','Bahan pengikat untuk beton dan adukan.',40),
  ('A','Besi Beton','','','Tulangan yang memperkuat beton pada elemen struktur.',50),
  ('A','Kawat Bendrat','','','Pengikat tulangan besi sebelum pengecoran.',60),
  ('B','Batako','','','Bahan pasangan dinding.',70),
  ('B','Semen Pasang','','','Bahan pengikat adukan pasangan dinding.',80),
  ('B','Pasir Pasang','','','Bahan campuran adukan pasangan dinding.',90),
  ('B','Acian Putih','','','Lapisan penghalus permukaan dinding sebelum pengecatan.',100),
  ('C','Rangka Baja Ringan TASO','TASO','','Rangka penopang penutup atap.',110),
  ('C','Canal','','','Profil baja ringan sebagai bagian rangka atap.',120),
  ('C','Reng','','','Rangka pendukung yang menahan penutup atap.',130),
  ('C','Spandek Black Matte','','Warna Black Matte','Penutup atap.',140),
  ('D','GRC Board','','','Lembaran penutup plafon.',150),
  ('D','Rangka plafon','','','Rangka penahan lembaran plafon.',160),
  ('D','Aksesori pemasangan plafon','','','Perlengkapan pendukung pemasangan plafon.',170),
  ('E','Kabel listrik','','','Penghantar listrik di dalam rumah.',180),
  ('E','Pipa instalasi listrik','','','Pelindung jalur kabel listrik.',190),
  ('E','Saklar','','','Pengatur penyalaan lampu.',200),
  ('E','Stop kontak','','','Titik sambungan peralatan listrik.',210),
  ('E','Lampu','','','Penerangan ruangan.',220),
  ('F','Pipa PVC','','','Saluran air bersih dan air buangan.',230),
  ('F','Sambungan pipa','','','Penghubung dan pengarah jalur pipa.',240),
  ('F','Instalasi air bersih','','','Jalur penyaluran air bersih ke titik pemakaian.',250),
  ('F','Instalasi pembuangan air kotor','','','Jalur pembuangan air kotor dari rumah.',260),
  ('G','Keramik lantai','','','Penutup dan finishing lantai.',270),
  ('G','Keramik kamar mandi','','','Penutup lantai dan dinding kamar mandi.',280),
  ('G','Cat interior','','','Pelapis dinding bagian dalam.',290),
  ('G','Cat eksterior','','','Pelapis dinding bagian luar.',300),
  ('G','Pintu dan jendela','','','Akses keluar-masuk serta jalur udara dan cahaya.',310),
  ('G','Kusen','','','Rangka pemasangan pintu dan jendela.',320),
  ('G','Perlengkapan sanitasi','','','Perlengkapan kamar mandi.',330)
) as v(category, name, brand, spec, function_desc, sort_order)
where not exists (select 1 from public.materials);
