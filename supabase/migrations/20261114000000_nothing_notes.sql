-- =====================================================================
--  Nothing Notes — schéma du backend (Supabase / PostgreSQL)
--
--  À exécuter UNE FOIS dans Supabase : Dashboard > SQL Editor > New query,
--  coller tout ce fichier, puis "Run". Le script est ré-exécutable.
--
--  Principes :
--   * chaque ligne appartient à un utilisateur (user_id) ; la RLS empêche
--     tout accès aux données d'un autre compte ;
--   * les clients ne peuvent PAS écrire directement dans les tables : toutes
--     les écritures passent par la fonction sync_push(), qui contrôle le
--     propriétaire, le numéro de version (détection des conflits) et
--     l'identifiant d'opération (anti-doublon en cas de nouvel envoi) ;
--   * chaque écriture reçoit un numéro de séquence serveur (server_seq)
--     croissant : les appareils ne téléchargent que ce qui a changé depuis
--     leur dernier curseur (synchronisation différentielle, paginée) ;
--   * les suppressions sont des "pierres tombales" (deleted / purged) afin
--     d'être propagées à tous les appareils.
-- =====================================================================

create sequence if not exists public.sync_seq;

-- ---------------------------------------------------------------- tables
create table if not exists public.folders (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  name              text not null default '',
  parent_id         uuid,
  color             text,
  position          double precision not null default 0,
  deleted           boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  device_id         text,
  version           bigint not null default 1,
  server_seq        bigint not null default 0,
  server_updated_at timestamptz not null default now()
);

create table if not exists public.tags (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  name              text not null default '',
  color             text,
  deleted           boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  device_id         text,
  version           bigint not null default 1,
  server_seq        bigint not null default 0,
  server_updated_at timestamptz not null default now()
);

create table if not exists public.notes (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  title             text not null default '',
  content           jsonb not null default '{"blocks":[]}'::jsonb,
  folder_id         uuid,
  tags              uuid[] not null default '{}',
  favorite          boolean not null default false,
  archived          boolean not null default false,
  trashed_at        timestamptz,
  purged            boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  device_id         text,
  version           bigint not null default 1,
  server_seq        bigint not null default 0,
  server_updated_at timestamptz not null default now(),
  constraint notes_content_size check (octet_length(content::text) <= 5000000)
);

create table if not exists public.attachments (
  id                uuid primary key,
  user_id           uuid not null references auth.users(id) on delete cascade,
  note_id           uuid not null,
  file_name         text not null default 'fichier',
  mime              text not null default 'application/octet-stream',
  size_bytes        bigint not null default 0,
  sha256            text,
  storage_path      text,
  deleted           boolean not null default false,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  device_id         text,
  version           bigint not null default 1,
  server_seq        bigint not null default 0,
  server_updated_at timestamptz not null default now()
);

-- Historique des versions des notes (alimenté par trigger).
create table if not exists public.note_versions (
  id         bigserial primary key,
  note_id    uuid not null,
  user_id    uuid not null references auth.users(id) on delete cascade,
  version    bigint not null,
  title      text not null default '',
  content    jsonb not null,
  device_id  text,
  reason     text not null default 'edit',
  saved_at   timestamptz not null default now()
);

-- Opérations déjà appliquées (idempotence des envois).
create table if not exists public.applied_ops (
  op_id      uuid primary key,
  user_id    uuid not null references auth.users(id) on delete cascade,
  entity     text not null,
  entity_id  uuid not null,
  applied_at timestamptz not null default now()
);

create index if not exists folders_user_seq     on public.folders     (user_id, server_seq);
create index if not exists tags_user_seq        on public.tags        (user_id, server_seq);
create index if not exists notes_user_seq       on public.notes       (user_id, server_seq);
create index if not exists attachments_user_seq on public.attachments (user_id, server_seq);
create index if not exists note_versions_note   on public.note_versions (note_id, saved_at desc);
create index if not exists applied_ops_time     on public.applied_ops (applied_at);

-- ---------------------------------------------------------------- triggers
create or replace function public.tg_sync_stamp() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' and new.user_id <> old.user_id then
    raise exception 'Changement de propriétaire interdit' using errcode = '42501';
  end if;
  new.server_seq := nextval('public.sync_seq');
  new.server_updated_at := now();
  return new;
end $$;

do $$
declare t text;
begin
  foreach t in array array['folders','tags','notes','attachments'] loop
    execute format('drop trigger if exists %I on public.%I', t || '_stamp', t);
    execute format('create trigger %I before insert or update on public.%I
                    for each row execute function public.tg_sync_stamp()', t || '_stamp', t);
  end loop;
end $$;

create or replace function public.tg_note_history() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if (old.title is distinct from new.title or old.content is distinct from new.content)
     and not old.purged then
    insert into public.note_versions(note_id, user_id, version, title, content, device_id, reason)
    values (old.id, old.user_id, old.version, old.title, old.content, old.device_id, 'edit');
    -- on conserve les 50 dernières versions par note
    delete from public.note_versions
     where note_id = old.id
       and id not in (select id from public.note_versions
                       where note_id = old.id order by saved_at desc, id desc limit 50);
  end if;
  if new.purged and not old.purged then
    delete from public.note_versions where note_id = old.id;
  end if;
  return new;
end $$;

drop trigger if exists notes_history on public.notes;
create trigger notes_history after update on public.notes
  for each row execute function public.tg_note_history();

-- ---------------------------------------------------------------- sécurité (RLS)
alter table public.folders       enable row level security;
alter table public.tags          enable row level security;
alter table public.notes         enable row level security;
alter table public.attachments   enable row level security;
alter table public.note_versions enable row level security;
alter table public.applied_ops   enable row level security;

do $$
declare t text;
begin
  foreach t in array array['folders','tags','notes','attachments','note_versions'] loop
    execute format('drop policy if exists %I on public.%I', t || '_select_own', t);
    execute format('create policy %I on public.%I for select to authenticated
                    using (user_id = (select auth.uid()))', t || '_select_own', t);
  end loop;
end $$;

-- Lecture seule pour les clients : toutes les écritures passent par sync_push().
revoke all on public.folders, public.tags, public.notes, public.attachments,
              public.note_versions, public.applied_ops from anon, authenticated;
grant select on public.folders, public.tags, public.notes, public.attachments,
                public.note_versions to authenticated;
revoke all on sequence public.sync_seq from anon, authenticated;

-- ---------------------------------------------------------------- RPC : envoi
-- p_entity       : 'notes' | 'folders' | 'tags' | 'attachments'
-- p_row          : la ligne complète au format JSON
-- p_base_version : version serveur sur laquelle la modification se base
--                  (0 = élément créé localement, jamais envoyé)
-- p_op_id        : identifiant unique de l'opération (anti-doublon)
-- Retour : {"status": "ok" | "conflict" | "duplicate", "row": {...}}
create or replace function public.sync_push(p_entity text, p_row jsonb,
                                            p_base_version bigint, p_op_id uuid)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_uid     uuid := auth.uid();
  v_id      uuid;
  v_owner   uuid;
  v_version bigint;
  v_cols    text;
  v_result  jsonb;
  v_current jsonb;
begin
  if v_uid is null then
    raise exception 'Non authentifié' using errcode = '28000';
  end if;
  if p_entity is null or p_entity not in ('notes','folders','tags','attachments') then
    raise exception 'Entité inconnue : %', p_entity using errcode = '22023';
  end if;
  if p_op_id is null then
    raise exception 'op_id manquant' using errcode = '22023';
  end if;
  begin
    v_id := (p_row->>'id')::uuid;
  exception when others then
    raise exception 'id invalide' using errcode = '22023';
  end;
  if v_id is null then
    raise exception 'id manquant' using errcode = '22023';
  end if;

  -- Sérialise les écritures d'un même compte : l'ordre des server_seq
  -- correspond alors à l'ordre de validation, aucun changement n'est sauté.
  perform pg_advisory_xact_lock(hashtextextended(v_uid::text, 42));

  -- Opération déjà appliquée (réponse perdue puis renvoi) : on ne rejoue pas.
  if exists (select 1 from public.applied_ops where op_id = p_op_id) then
    if not exists (select 1 from public.applied_ops where op_id = p_op_id and user_id = v_uid) then
      raise exception 'Accès refusé' using errcode = '42501';
    end if;
    execute format('select to_jsonb(t) from public.%I t where id = $1 and user_id = $2', p_entity)
      into v_result using v_id, v_uid;
    return jsonb_build_object('status', 'duplicate', 'row', v_result);
  end if;

  execute format('select user_id, version, to_jsonb(t) from public.%I t where id = $1 for update', p_entity)
    into v_owner, v_version, v_current using v_id;

  if v_owner is not null and v_owner <> v_uid then
    raise exception 'Accès refusé' using errcode = '42501';
  end if;

  -- Détection de conflit : la modification ne se base pas sur la dernière version.
  if v_version is not null and v_version <> coalesce(p_base_version, 0) then
    return jsonb_build_object('status', 'conflict', 'row', v_current);
  end if;

  -- Champs imposés par le serveur.
  p_row := coalesce(v_current, '{}'::jsonb)
           || (p_row - 'user_id' - 'version' - 'server_seq' - 'server_updated_at')
           || jsonb_build_object('user_id', v_uid,
                                 'version', coalesce(v_version, 0) + 1,
                                 'server_seq', 0,
                                 'server_updated_at', now());
  if v_current is not null then
    p_row := p_row || jsonb_build_object('created_at', v_current->'created_at');
  end if;

  select string_agg(format('%I = excluded.%I', attname, attname), ', ')
    into v_cols
    from pg_attribute
   where attrelid = format('public.%I', p_entity)::regclass
     and attnum > 0 and not attisdropped
     and attname not in ('id', 'user_id', 'created_at');

  execute format(
    'insert into public.%1$I as t select * from jsonb_populate_record(null::public.%1$I, $1)
     on conflict (id) do update set %2$s
     returning to_jsonb(t)', p_entity, v_cols)
    into v_result using p_row;

  insert into public.applied_ops(op_id, user_id, entity, entity_id)
  values (p_op_id, v_uid, p_entity, v_id);

  return jsonb_build_object('status', 'ok', 'row', v_result);
end $$;

-- ---------------------------------------------------------------- RPC : historique
-- Enregistre une version locale abandonnée lors d'une résolution de conflit,
-- pour qu'elle reste restaurable.
create or replace function public.save_note_version(p_note_id uuid, p_title text,
                                                    p_content jsonb, p_device_id text)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_uid uuid := auth.uid(); v_owner uuid; v_version bigint;
begin
  if v_uid is null then raise exception 'Non authentifié' using errcode = '28000'; end if;
  select user_id, version into v_owner, v_version from public.notes where id = p_note_id;
  if v_owner is distinct from v_uid then raise exception 'Accès refusé' using errcode = '42501'; end if;
  insert into public.note_versions(note_id, user_id, version, title, content, device_id, reason)
  values (p_note_id, v_uid, v_version, coalesce(p_title, ''), coalesce(p_content, '{"blocks":[]}'::jsonb),
          p_device_id, 'conflict');
end $$;

-- ---------------------------------------------------------------- RPC : compte
-- Supprime définitivement le compte et toutes ses données (cascade).
-- Les fichiers du stockage sont supprimés par l'application juste avant.
create or replace function public.delete_my_account()
returns void
language plpgsql security definer set search_path = public, auth, pg_temp as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then raise exception 'Non authentifié' using errcode = '28000'; end if;
  delete from auth.users where id = v_uid;
end $$;

-- Nettoyage des opérations anciennes (appelée par l'application, sans risque).
create or replace function public.cleanup_my_ops()
returns void
language sql security definer set search_path = public, pg_temp as $$
  delete from public.applied_ops
   where user_id = auth.uid() and applied_at < now() - interval '30 days';
$$;

revoke all on function public.sync_push(text, jsonb, bigint, uuid) from public, anon;
revoke all on function public.save_note_version(uuid, text, jsonb, text) from public, anon;
revoke all on function public.delete_my_account() from public, anon;
revoke all on function public.cleanup_my_ops() from public, anon;
revoke all on function public.tg_sync_stamp() from public, anon, authenticated;
revoke all on function public.tg_note_history() from public, anon, authenticated;
grant execute on function public.sync_push(text, jsonb, bigint, uuid) to authenticated;
grant execute on function public.save_note_version(uuid, text, jsonb, text) to authenticated;
grant execute on function public.delete_my_account() to authenticated;
grant execute on function public.cleanup_my_ops() to authenticated;

-- ---------------------------------------------------------------- stockage des pièces jointes
-- Bucket privé ; chaque utilisateur n'accède qu'au dossier <son uid>/...
insert into storage.buckets (id, name, public, file_size_limit)
values ('attachments', 'attachments', false, 52428800)
on conflict (id) do update set public = false, file_size_limit = 52428800;

drop policy if exists "nn_attachments_select" on storage.objects;
drop policy if exists "nn_attachments_insert" on storage.objects;
drop policy if exists "nn_attachments_update" on storage.objects;
drop policy if exists "nn_attachments_delete" on storage.objects;

create policy "nn_attachments_select" on storage.objects for select to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "nn_attachments_insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "nn_attachments_update" on storage.objects for update to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);
create policy "nn_attachments_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'attachments' and (storage.foldername(name))[1] = (select auth.uid())::text);

-- ---------------------------------------------------------------- temps réel
-- Les appareils sont prévenus instantanément d'un changement (la RLS s'applique).
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['folders','tags','notes','attachments'] loop
      if not exists (select 1 from pg_publication_tables
                      where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
