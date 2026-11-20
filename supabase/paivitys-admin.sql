-- =====================================================================
-- Farmikoulu: admin-paneelin lisäys Supabaseen
-- Aja tämä KERRAN: Supabase → SQL Editor → New query → liitä → Run.
-- (Ajetaan alkuperäisen asennusskriptin JÄLKEEN. Voi ajaa uudelleen.)
-- Kaikki toiminnot tarkistavat palvelimella, että kutsuja on leetu1234.
-- =====================================================================

create or replace function public.fk_is_admin(p_token text)
returns boolean language sql security definer
set search_path = public, extensions as $$
  select exists (select 1 from public.fk_players
                  where id = 'leetu1234' and token = p_token and p_token is not null);
$$;
revoke all on function public.fk_is_admin(text) from public, anon, authenticated;

-- Vaihda pelaajan PIN (poistaa myös lukituksen)
create or replace function public.fk_admin_set_pin(p_admin_token text, p_id text, p_pin text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not public.fk_is_admin(p_admin_token) or coalesce(p_pin, '') !~ '^[0-9]{4,6}$' then
    return jsonb_build_object('ok', false);
  end if;
  update public.fk_players
     set pin_hash = crypt(p_pin, gen_salt('bf')), fails = 0, locked_until = null
   where id = p_id;
  return jsonb_build_object('ok', found);
end $$;

-- Poista käyttäjä (ylläpitäjää ei voi poistaa)
create or replace function public.fk_admin_delete_user(p_admin_token text, p_id text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not public.fk_is_admin(p_admin_token) or p_id = 'leetu1234' then
    return jsonb_build_object('ok', false);
  end if;
  delete from public.fk_players where id = p_id;
  return jsonb_build_object('ok', found);
end $$;

-- Tulostaulun rivit tunnisteineen
create or replace function public.fk_admin_scores(p_admin_token text)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not public.fk_is_admin(p_admin_token) then return jsonb_build_object('ok', false); end if;
  return jsonb_build_object('ok', true, 'scores',
    (select coalesce(jsonb_agg(x order by x.time), '[]'::jsonb)
       from (select id, name, time, level, acc, to_char(created, 'YYYY-MM-DD') as date
               from public.fk_scores order by time limit 500) x));
end $$;

-- Poista tulostaulun rivi
create or replace function public.fk_admin_delete_score(p_admin_token text, p_score_id bigint)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not public.fk_is_admin(p_admin_token) then return jsonb_build_object('ok', false); end if;
  delete from public.fk_scores where id = p_score_id;
  return jsonb_build_object('ok', found);
end $$;

revoke all on function public.fk_admin_set_pin(text, text, text), public.fk_admin_delete_user(text, text),
  public.fk_admin_scores(text), public.fk_admin_delete_score(text, bigint) from public;
grant execute on function public.fk_admin_set_pin(text, text, text), public.fk_admin_delete_user(text, text),
  public.fk_admin_scores(text), public.fk_admin_delete_score(text, bigint) to anon, authenticated;

notify pgrst, 'reload schema';
