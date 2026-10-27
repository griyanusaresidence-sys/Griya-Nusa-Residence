# Panduan Fitur Progres Pembangunan — Griya Nusa Residence

Fitur ini butuh **backend** karena GitHub Pages hanya menyajikan berkas statis. Kami memakai **Supabase** (gratis untuk skala ini):
login admin, database dengan aturan akses (Row Level Security), dan penyimpanan foto privat.
Selama langkah di bawah belum dilakukan, situs menampilkan "belum terhubung" dan **tidak ada data yang tersimpan**.

## 1. Siapkan Supabase (±15 menit, sekali saja)

1. Buat akun di https://supabase.com, lalu **New project** (region terdekat, mis. Singapore). Simpan *Database password* di tempat aman.
2. Buka **SQL Editor → New query**, tempel seluruh isi `sql/schema.sql`, klik **Run**. (Aman dijalankan ulang.)
   - Jika muncul galat soal kebijakan `storage.objects`, buat 4 kebijakan itu lewat **Storage → Policies** dengan ekspresi yang sama seperti di bagian 6 berkas SQL.
3. Buat akun admin pertama: **Authentication → Users → Add user** (isi email + kata sandi kuat, centang *Auto Confirm User*).
4. Daftarkan sebagai admin (SQL Editor, ganti emailnya):
   ```sql
   insert into public.admins (user_id, email, role)
   select id, email, 'owner' from auth.users where email = 'email-admin@contoh.com';
   ```
   `owner` = akses penuh. Untuk staf lapangan pakai `'editor'` (hanya ubah status/persen tahap, unggah foto, terbitkan; tidak bisa mengubah bobot, menghapus unit, atau menghapus foto orang lain).
5. **Authentication → Sign In / Providers**: matikan **Allow new users to sign up**, supaya tidak ada orang asing bisa membuat akun.
6. **Project Settings → API**: salin **Project URL** dan **anon public key**. (Jangan pakai `service_role`.)
7. Di repo GitHub, edit `progress-config.js`, isi `url` dan `anonKey`, commit. Tunggu ±1 menit, muat ulang situs.
   Kunci *anon* memang publik; yang melindungi data adalah aturan akses di database, bukan kerahasiaan kunci itu.

## 2. Pemakaian harian (admin)

Buka `…/#admin` (atau tautan kecil "Masuk admin proyek" di footer), login.

1. **Impor dari site plan** (kavling terjual sudah tercentang) atau **+ Tambah unit**. Delapan tahap standar dibuat otomatis.
2. Tab **Progres**: ubah status tiap tahap; isi persen hanya untuk tahap *Sedang dikerjakan*. Owner dapat mengubah nama tahap & **bobot** (total ideal 100). Persentase keseluruhan = Σ(bobot × persen tahap) ÷ Σ bobot.
   Bobot bawaan (5/15/20/10/12/15/15/8) hanyalah **titik awal**: sesuaikan dengan RAB/pembobotan resmi proyek Anda. Template untuk unit baru: tombol **Template tahap**.
3. Tab **Foto**: pilih foto asli dari lapangan, isi tanggal, tahap, dan keterangan (wajib). Foto dikompres otomatis dan disimpan di bucket privat.
4. Tab **Info & catatan**: tipe rumah, tanggal pembaruan, catatan tim, estimasi tahap berikutnya.
5. **Simpan perubahan**, lalu **Terbitkan ke customer**. Customer hanya melihat apa yang sudah *diterbitkan* (draf Anda tidak terlihat). Untuk menyembunyikan satu unit dari publik, hilangkan centang "Unit dapat dibuka customer".
6. Tab **Info & catatan** menyediakan **tautan progres** unit (mis. `…/#progres/D-9`) beserta pesan WhatsApp siap kirim. Tautan ini terbuka untuk siapa saja.
7. Tab **Riwayat**: seluruh perubahan beserta waktu dan akun yang melakukannya, plus daftar versi yang pernah diterbitkan.

## 3. Cara customer memakai

Buka `…/#progres` (atau menu **Progres Pembangunan**) → ketik blok/kavling (mis. `D-9`, `Blok D9`) atau pilih dari daftar unit yang sudah punya pembaruan → lihat ringkasan, timeline 8 tahap, galeri foto, riwayat, catatan, estimasi, dan tombol **Hubungi Admin** (WhatsApp). Tautan `…/#progres/D-9` langsung membuka unit tersebut.
**Tidak ada kode akses**: progres yang sudah diterbitkan bersifat publik. Karena itu jangan menulis data pribadi pembeli di catatan tim atau keterangan foto.

## 4. Keamanan: apa yang dijaga di mana

| Hal | Dijaga oleh |
|---|---|
| Hanya admin yang bisa mengubah data | Supabase Auth + tabel `admins` + RLS di setiap tabel |
| Yang bisa dilihat publik | Hanya lewat fungsi `public_progress(unit)` dan `public_units()`: data yang **sudah diterbitkan**, tanpa catatan internal, tanpa email admin. Tabel tidak bisa dibaca langsung oleh publik |
| Foto | Bucket tidak publik; link foto dibuat sementara (1 jam) dan hanya untuk unit yang sedang dibuka |
| Data pribadi customer | Tidak disimpan. Kolom "catatan internal" (opsional) hanya terbaca admin |
| Kredensial | Tidak ada password/service key di kode situs; hanya URL + anon key publik |
| Jejak perubahan | `audit_log`, tidak bisa diubah/dihapus dari aplikasi |

## 5. Catatan operasional

- Proyek Supabase gratis dijeda bila tidak aktif lama; buka dashboard secara berkala atau pertimbangkan paket berbayar untuk produksi.
- Aktifkan backup / ekspor database berkala. Batas gratis: 500 MB database, 1 GB foto (foto ±200–400 KB setelah dikompres).
- Menambah admin/editor: buat user di Authentication, lalu `insert into public.admins …` seperti langkah 4.
- Mencabut akses admin: `delete from public.admins where email = '…';` (dan hapus user-nya).
- Pratinjau Claude (artifact) tidak bisa menghubungi server data; fitur ini hanya aktif di situs GitHub Pages.

## 6. Status pengujian (jujur)

Sudah diuji otomatis di mesin lokal dengan **PostgreSQL 16 + PostgREST sungguhan + pustaka supabase-js sungguhan**: skema & RLS, akses publik hanya ke data terbit, hak owner vs editor, foto + izin sementara, audit, publikasi versi, login admin, unggah/hapus foto, persistensi setelah muat ulang, kondisi offline, tampilan HP.
Yang **ditiru** dalam uji lokal: layanan Auth (GoTrue) dan Storage Supabase (bentuk API sama, tetapi bukan server aslinya). Karena itu setelah Anda menghubungkan proyek Supabase sungguhan, lakukan daftar periksa singkat ini:

1. Login admin berhasil; akun non-admin ditolak.
2. Buat unit, unggah 1 foto, terbitkan.
3. Di jendela penyamaran: buka `#progres/D-9` → ringkasan dan foto tampil.
4. Di jendela yang sama pastikan tidak ada tombol/ubah apa pun; hanya login admin yang bisa mengedit.
Jika ada yang gagal, kirimkan pesan galatnya ke saya.
