-- =====================================================================
-- Farmikoulu: modit (sininen nimi ja mod-paneeli)
-- Aja tämä KERRAN: Supabase → SQL Editor → New query → liitä → Run.
-- Ajetaan aiempien skriptien JÄLKEEN. Voi ajaa uudelleen.
-- Vain leetu1234 voi antaa tai poistaa mod-statuksen (tarkistetaan palvelimella).
-- =====================================================================

alter table public.fk_players add column if not exists is_mod boolean not null default false;

-- Anna tai poista mod-status
create or replace function public.fk_admin_set_mod(p_admin_token text, p_id text, p_mod boolean)
returns jsonb language plpgsql security definer
set search_path = public, extensions as $$
begin
  if not public.fk_is_admin(p_admin_token) or p_id = 'leetu1234' then
    return jsonb_build_object('ok', false);
  end if;
  update public.fk_players set is_mod = coalesce(p_mod, false) where id = p_id;
  return jsonb_build_object('ok', found);
end $$;

-- Modien tunnukset (julkinen lista, jotta modien nimet näkyvät sinisinä kaikille)
create or replace function public.fk_mods()
returns jsonb language sql security definer
set search_path = public, extensions as $$
  select coalesce(jsonb_agg(id order by id), '[]'::jsonb) from public.fk_players where is_mod;
$$;

revoke all on function public.fk_admin_set_mod(text, text, boolean), public.fk_mods() from public;
grant execute on function public.fk_admin_set_mod(text, text, boolean), public.fk_mods() to anon, authenticated;
