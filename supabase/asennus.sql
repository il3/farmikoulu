-- =====================================================================
-- Farmikoulu: Supabase-tietokannan asennus
-- Aja tämä KERRAN: Supabase → oma projekti → SQL Editor → New query →
-- liitä koko teksti → Run. Skriptin voi ajaa uudelleen turvallisesti.
--
-- Tietoturva:
--  * Selain ei pääse tauluihin suoraan (RLS päällä, oikeudet poistettu).
--  * Kaikki tapahtuu alla olevien funktioiden kautta.
--  * PIN-koodit tallennetaan bcrypt-tiivisteinä, eikä niitä koskaan
--    palauteta selaimeen.
--  * 8 väärää PIN-yritystä lukitsee käyttäjän 5 minuutiksi.
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.fk_players (
  id           text primary key check (id ~ '^[a-z0-9_-]{1,24}$'),
  name         text not null check (char_length(name) between 1 and 16),
  pin_hash     text not null,
  token        text,
  save         jsonb not null default '{}'::jsonb,
  updated      bigint not null default 0,
  fails        int not null default 0,
  locked_until timestamptz,
  created      timestamptz not null default now()
);

create table if not exists public.fk_scores (
  id      bigserial primary key,
  name    text not null check (char_length(name) between 1 and 16),
  time    int  not null check (time > 0),
  level   int  not null,
  acc     text,
  created timestamptz not null default now()
);

alter table public.fk_players enable row level security;
alter table public.fk_scores  enable row level security;
revoke all on table public.fk_players, public.fk_scores from anon, authenticated;
revoke all on sequence public.fk_scores_id_seq from anon, authenticated;

-- ---------------------------------------------------------------------
-- Kirjautuminen tai uuden käyttäjän luonti
-- ---------------------------------------------------------------------
create or replace function public.fk_login(p_id text, p_name text, p_pin text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare
  r  public.fk_players;
  t  text;
  nm text := trim(left(regexp_replace(coalesce(p_name, ''), '[<>"&]', '', 'g'), 16));
begin
  if coalesce(p_id, '') !~ '^[a-z0-9_-]{1,24}$'
     or coalesce(p_pin, '') !~ '^[0-9]{4,6}$'
     or length(nm) = 0 then
    return jsonb_build_object('ok', false, 'err', 'bad');
  end if;

  select * into r from public.fk_players where id = p_id for update;

  if not found then
    -- Ylläpitäjän käyttäjä luodaan vain tällä skriptillä (alla).
    if p_id = 'leetu1234' then
      return jsonb_build_object('ok', false, 'err', 'pin');
    end if;
    t := encode(gen_random_bytes(18), 'hex');
    insert into public.fk_players (id, name, pin_hash, token)
    values (p_id, nm, crypt(p_pin, gen_salt('bf')), t);
    return jsonb_build_object('ok', true, 'created', true, 'token', t, 'name', nm, 'admin', false);
  end if;

  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'err', 'locked');
  end if;

  if r.pin_hash <> crypt(p_pin, r.pin_hash) then
    if r.fails + 1 >= 8 then
      update public.fk_players set fails = 0, locked_until = now() + interval '5 minutes' where id = p_id;
    else
      update public.fk_players set fails = r.fails + 1 where id = p_id;
    end if;
    return jsonb_build_object('ok', false, 'err', 'pin');
  end if;

  t := coalesce(r.token, encode(gen_random_bytes(18), 'hex'));
  update public.fk_players set fails = 0, locked_until = null, token = t where id = p_id;
  return jsonb_build_object('ok', true, 'created', false, 'token', t, 'name', r.name,
                            'save', r.save, 'updated', r.updated, 'admin', p_id = 'leetu1234');
end $$;

-- Automaattinen kirjautuminen samalla laitteella (tunniste, ei PIN)
create or replace function public.fk_resume(p_id text, p_token text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare r public.fk_players;
begin
  select * into r from public.fk_players where id = p_id and token = p_token and p_token is not null;
  if not found then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'name', r.name, 'save', r.save, 'updated', r.updated, 'admin', r.id = 'leetu1234');
end $$;

-- Pelin tallennus
create or replace function public.fk_save(p_id text, p_token text, p_save jsonb)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if p_save is null or octet_length(p_save::text) > 300000 then
    return jsonb_build_object('ok', false);
  end if;
  update public.fk_players
     set save = p_save, updated = (extract(epoch from now()) * 1000)::bigint
   where id = p_id and token = p_token and p_token is not null;
  return jsonb_build_object('ok', found);
end $$;

-- Tulos tulostaululle (vain kirjautuneelle pelaajalle)
create or replace function public.fk_submit_score(p_id text, p_token text, p_time int, p_level int)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare nm text;
begin
  if p_time is null or p_time <= 0 or p_time > 864000 or p_level not in (34, 5, 6, 78) then
    return jsonb_build_object('ok', false);
  end if;
  select name into nm from public.fk_players where id = p_id and token = p_token and p_token is not null;
  if nm is null then return jsonb_build_object('ok', false); end if;
  insert into public.fk_scores (name, time, level, acc) values (nm, p_time, p_level, p_id);
  return jsonb_build_object('ok', true, 'rank', (select count(*) from public.fk_scores where time < p_time) + 1);
end $$;

-- Tulostaulu: kaikki parhaat suoritukset
create or replace function public.fk_top(p_limit int)
returns jsonb language sql security definer
set search_path = public, extensions as $$
  select coalesce(jsonb_agg(x order by x.time), '[]'::jsonb)
  from (select name, time, level, acc, to_char(created, 'YYYY-MM-DD') as date
          from public.fk_scores
         order by time
         limit least(greatest(coalesce(p_limit, 100), 1), 200)) x;
$$;

-- Ylläpitäjä: kaikki käyttäjät
create or replace function public.fk_admin_list(p_admin_token text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.fk_players where id = 'leetu1234' and token = p_admin_token and p_admin_token is not null) then
    return jsonb_build_object('ok', false);
  end if;
  return jsonb_build_object('ok', true, 'users',
    (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'name', name, 'owned', save -> 'owned',
                                                  'boss', save ->> 'boss', 'updated', updated)
                               order by updated desc), '[]'::jsonb)
       from public.fk_players));
end $$;

-- Ylläpitäjä: siirry pelaajan peliin
create or replace function public.fk_admin_open(p_admin_token text, p_id text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
declare r public.fk_players; t text;
begin
  if not exists (select 1 from public.fk_players where id = 'leetu1234' and token = p_admin_token and p_admin_token is not null) then
    return jsonb_build_object('ok', false);
  end if;
  select * into r from public.fk_players where id = p_id;
  if not found then return jsonb_build_object('ok', false); end if;
  t := coalesce(r.token, encode(gen_random_bytes(18), 'hex'));
  if r.token is null then update public.fk_players set token = t where id = p_id; end if;
  return jsonb_build_object('ok', true, 'name', r.name, 'token', t, 'save', r.save, 'updated', r.updated);
end $$;

revoke all on function public.fk_login(text, text, text), public.fk_resume(text, text),
  public.fk_save(text, text, jsonb), public.fk_submit_score(text, text, int, int), public.fk_top(int),
  public.fk_admin_list(text), public.fk_admin_open(text, text) from public;
grant execute on function public.fk_login(text, text, text), public.fk_resume(text, text),
  public.fk_save(text, text, jsonb), public.fk_submit_score(text, text, int, int), public.fk_top(int),
  public.fk_admin_list(text), public.fk_admin_open(text, text) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Ylläpitäjä leetu1234. Vaihda PIN tähän ennen ajamista, jos haluat.
-- ---------------------------------------------------------------------
insert into public.fk_players (id, name, pin_hash, token)
values ('leetu1234', 'leetu1234', crypt('VAIHDA_TAHAN_ADMIN_PIN', gen_salt('bf')), encode(gen_random_bytes(18), 'hex'))
on conflict (id) do update set pin_hash = excluded.pin_hash;

notify pgrst, 'reload schema';
