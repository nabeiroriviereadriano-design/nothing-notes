-- Tests du backend Nothing Notes (exécutés en CI et en local).
-- Usage : psql -v ON_ERROR_STOP=1 -f stub_supabase.sql -f ../migrations/*.sql -f backend_test.sql
\set ON_ERROR_STOP 1

create or replace function public.t_assert(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ÉCHEC : %', msg; end if;
  raise notice 'OK : %', msg;
end $$;
grant execute on function public.t_assert(boolean, text) to authenticated;

insert into auth.users(id, email) values
  ('11111111-1111-1111-1111-111111111111', 'alice@test.fr'),
  ('22222222-2222-2222-2222-222222222222', 'bob@test.fr')
on conflict do nothing;

-- ===================================================== Alice crée une note
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';

select t_assert(
  (sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"Courses","content":{"blocks":[{"id":"b1","type":"todo","text":"Pain","checked":false}]},"folder_id":null,"tags":["cccccccc-0000-0000-0000-000000000001"],"favorite":false,"archived":false,"trashed_at":null,"purged":false,"created_at":"2026-11-14T10:00:00Z","updated_at":"2026-11-14T10:00:00Z","device_id":"android"}'::jsonb,
             0, 'eeeeeeee-0000-0000-0000-000000000001')->>'status') = 'ok',
  'création d''une note');

select t_assert((select version from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1, 'version 1 après création');
select t_assert((select tags[1]::text from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'cccccccc-0000-0000-0000-000000000001', 'étiquettes stockées en uuid[]');
select t_assert((select user_id from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = '11111111-1111-1111-1111-111111111111', 'user_id imposé par le serveur');

-- Renvoi de la même opération (réponse perdue) : pas de double application
select t_assert(
  (sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"Courses"}'::jsonb,
             0, 'eeeeeeee-0000-0000-0000-000000000001')->>'status') = 'duplicate',
  'opération déjà appliquée détectée (doublon)');
select t_assert((select version from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1, 'doublon non rejoué');

-- Modification "Windows" basée sur la version 1
select t_assert(
  (sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"Courses du samedi","device_id":"windows"}'::jsonb,
             1, 'eeeeeeee-0000-0000-0000-000000000002')->>'status') = 'ok',
  'modification basée sur la dernière version');
select t_assert((select version from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 2, 'version 2');
select t_assert((select content->'blocks'->0->>'text' from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'Pain', 'mise à jour partielle : le contenu est conservé');
select t_assert((select count(*) from note_versions where note_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 1, 'ancienne version archivée dans l''historique');

-- Modification "Android" hors ligne basée sur la version 1 => conflit
select t_assert(
  (sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"Courses (tel)"}'::jsonb,
             1, 'eeeeeeee-0000-0000-0000-000000000003')->>'status') = 'conflict',
  'modification concurrente détectée comme conflit');
select t_assert((select title from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001') = 'Courses du samedi', 'aucun écrasement silencieux');

-- Synchro différentielle : seq croissant
select t_assert((select count(*) from notes where server_seq > 0) = 1, 'lecture de ses propres notes');

-- Écriture directe interdite (doit passer par sync_push)
do $$ begin
  begin
    insert into notes(id, user_id) values ('aaaaaaaa-0000-0000-0000-0000000000ff', '11111111-1111-1111-1111-111111111111');
    raise exception 'ÉCHEC : écriture directe autorisée';
  exception when insufficient_privilege then raise notice 'OK : écriture directe refusée';
  end;
end $$;

-- Pièce jointe : stockage limité à son dossier
insert into storage.objects(bucket_id, name) values ('attachments', '11111111-1111-1111-1111-111111111111/a1/photo.jpg');
do $$ begin
  begin
    insert into storage.objects(bucket_id, name) values ('attachments', '22222222-2222-2222-2222-222222222222/a1/pirate.jpg');
    raise exception 'ÉCHEC : écriture dans le dossier d''un autre';
  exception when insufficient_privilege then raise notice 'OK : stockage dans le dossier d''un autre refusé';
  end;
end $$;
reset role;

-- ===================================================== Bob tente d'accéder aux données d'Alice
set role authenticated;
set request.jwt.claim.sub = '22222222-2222-2222-2222-222222222222';
select t_assert((select count(*) from notes) = 0, 'Bob ne voit pas les notes d''Alice');
select t_assert((select count(*) from note_versions) = 0, 'Bob ne voit pas l''historique d''Alice');
select t_assert((select count(*) from storage.objects) = 0, 'Bob ne voit pas les fichiers d''Alice');

do $$ begin
  begin
    perform sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"piraté"}'::jsonb, 2, 'eeeeeeee-0000-0000-0000-0000000000b1');
    raise exception 'ÉCHEC : Bob a modifié la note d''Alice';
  exception when insufficient_privilege then raise notice 'OK : Bob ne peut pas modifier la note d''Alice';
  end;
  begin
    perform sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","title":"piraté"}'::jsonb, 2, 'eeeeeeee-0000-0000-0000-000000000002');
    raise exception 'ÉCHEC : Bob a réutilisé un op_id d''Alice';
  exception when insufficient_privilege then raise notice 'OK : Bob ne peut pas réutiliser une opération d''Alice';
  end;
  begin
    perform save_note_version('aaaaaaaa-0000-0000-0000-000000000001', 'x', '{}'::jsonb, 'x');
    raise exception 'ÉCHEC : Bob a écrit dans l''historique d''Alice';
  exception when insufficient_privilege then raise notice 'OK : historique d''Alice protégé';
  end;
end $$;

-- Bob crée ses propres éléments
select t_assert(
  (sync_push('folders', '{"id":"ffffffff-0000-0000-0000-000000000001","name":"Perso","parent_id":null,"color":null,"position":0,"deleted":false,"created_at":"2026-11-14T10:00:00Z","updated_at":"2026-11-14T10:00:00Z","device_id":"bob"}'::jsonb,
             0, 'eeeeeeee-0000-0000-0000-0000000000b2')->>'status') = 'ok', 'Bob crée un dossier');
reset role;

-- ===================================================== Anonyme
set role anon;
do $$ begin
  begin
    perform count(*) from public.notes;
    raise exception 'ÉCHEC : accès anonyme aux notes';
  exception when insufficient_privilege then raise notice 'OK : accès anonyme refusé';
  end;
end $$;
reset role;

-- ===================================================== Suppression (pierre tombale) puis suppression du compte
set role authenticated;
set request.jwt.claim.sub = '11111111-1111-1111-1111-111111111111';
select t_assert(
  (sync_push('notes', '{"id":"aaaaaaaa-0000-0000-0000-000000000001","purged":true,"title":"","content":{"blocks":[]}}'::jsonb,
             2, 'eeeeeeee-0000-0000-0000-000000000004')->>'status') = 'ok', 'suppression définitive (pierre tombale)');
select t_assert((select purged from notes where id = 'aaaaaaaa-0000-0000-0000-000000000001'), 'pierre tombale propagée via la table');
select t_assert((select count(*) from note_versions where note_id = 'aaaaaaaa-0000-0000-0000-000000000001') = 0, 'historique effacé avec la note');
select delete_my_account();
reset role;
select t_assert((select count(*) from auth.users where id = '11111111-1111-1111-1111-111111111111') = 0, 'compte supprimé');
select t_assert((select count(*) from public.notes where user_id = '11111111-1111-1111-1111-111111111111') = 0, 'données du compte supprimées en cascade');
select t_assert((select count(*) from public.folders where user_id = '22222222-2222-2222-2222-222222222222') = 1, 'données de Bob intactes');

\echo 'TOUS LES TESTS BACKEND SONT PASSÉS'
