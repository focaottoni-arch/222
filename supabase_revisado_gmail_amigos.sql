-- Ottoni - SQL completo para amigos, notificações, perfis e grupos
-- Execute TODO este arquivo no Supabase > SQL Editor do MESMO projeto.

create extension if not exists pgcrypto;

-- Compatibilidade com versões anteriores: algumas funções já podem existir
-- com outro tipo de retorno. O PostgreSQL não permite mudar o retorno com
-- CREATE OR REPLACE, então removemos somente essas funções antes de recriá-las.
-- Isso NÃO remove tabelas, contas, amizades, grupos ou mensagens.
drop function if exists public.send_friend_request(uuid);
drop function if exists public.respond_friend_request(uuid, boolean);
drop function if exists public.create_group_with_members(text, uuid[]);
drop function if exists public.add_group_members(uuid, uuid[]);

-- =========================
-- PERFIS
-- =========================
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  name text,
  topic text,
  photo text default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists username text;
alter table public.profiles add column if not exists name text;
alter table public.profiles add column if not exists topic text;
alter table public.profiles add column if not exists photo text default '';
alter table public.profiles add column if not exists created_at timestamptz not null default now();
alter table public.profiles add column if not exists updated_at timestamptz not null default now();
create unique index if not exists profiles_username_key on public.profiles (lower(username));
create index if not exists profiles_name_idx on public.profiles (lower(name));
alter table public.profiles enable row level security;

drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile" on public.profiles for select to authenticated using (auth.uid() = id);
-- Compatibilidade com a busca de amigos caso o PostgREST ainda não tenha
-- atualizado o schema cache da RPC. A interface seleciona apenas id, username
-- e name; nenhum e-mail é armazenado nesta tabela.
drop policy if exists "Authenticated users can view public profiles" on public.profiles;
create policy "Authenticated users can view public profiles" on public.profiles for select to authenticated using (true);
drop policy if exists "Users can create own profile" on public.profiles;
create policy "Users can create own profile" on public.profiles for insert to authenticated with check (auth.uid() = id);
drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile" on public.profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

-- Diretório seguro para busca: somente identificadores públicos do perfil.
drop view if exists public.user_directory;
-- O diretório contém somente dados públicos do perfil.
-- SECURITY INVOKER fica desativado para que a RLS de profiles (que protege
-- cada perfil para leitura direta) não impeça a busca de outras pessoas.
create view public.user_directory
with (security_invoker = false)
as
select id, username, name
from public.profiles;
grant select on public.user_directory to authenticated;

-- Corrige contas antigas que foram criadas antes do trigger de perfil.
-- Não cria contas novas: apenas cria o perfil que estiver faltando para
-- cada auth.users existente. O UUID do Auth continua sendo o ID oficial.
do $$
declare
  u record;
  base_username text;
  candidate text;
  suffix text;
  n integer;
begin
  for u in select id, email, raw_user_meta_data from auth.users loop
    if not exists (select 1 from public.profiles where id = u.id) then
      base_username := lower(coalesce(
        u.raw_user_meta_data->>'username',
        u.raw_user_meta_data->>'name',
        split_part(coalesce(u.email, ''), '@', 1),
        'usuario'
      ));
      base_username := regexp_replace(base_username, '[^a-z0-9._-]', '', 'g');
      base_username := left(base_username, 40);
      if base_username = '' then base_username := 'usuario'; end if;
      candidate := base_username;
      suffix := '_' || substr(replace(u.id::text, '-', ''), 1, 8);
      n := 0;
      while exists (select 1 from public.profiles where lower(username) = lower(candidate)) loop
        n := n + 1;
        candidate := left(base_username, greatest(1, 40 - length(suffix))) || suffix;
        if n > 1 then
          suffix := '_' || substr(replace(u.id::text, '-', ''), 1, 8) || '_' || substr(md5(random()::text), 1, 4);
        end if;
      end loop;
      insert into public.profiles (id, username, name)
      values (u.id, candidate, coalesce(u.raw_user_meta_data->>'name', candidate));
    end if;
  end loop;
end $$;

-- Perfil automático no cadastro. O loop evita colisão de username entre contas.
create or replace function public.handle_new_user_profile()
returns trigger language plpgsql security definer set search_path = public
as $$
declare
  base_username text;
  candidate text;
  suffix text;
  n integer := 0;
begin
  base_username := lower(coalesce(new.raw_user_meta_data->>'username', new.raw_user_meta_data->>'name', split_part(coalesce(new.email, ''), '@', 1), 'usuario'));
  base_username := regexp_replace(base_username, '[^a-z0-9._-]', '', 'g');
  base_username := left(base_username, 40);
  if base_username = '' then base_username := 'usuario'; end if;
  candidate := base_username;
  suffix := '_' || substr(replace(new.id::text, '-', ''), 1, 8);
  while exists (select 1 from public.profiles where lower(username) = lower(candidate)) loop
    candidate := left(base_username, 31) || suffix;
    n := n + 1;
    exit when n > 1;
    suffix := suffix || substr(md5(random()::text), 1, 4);
  end loop;
  insert into public.profiles (id, username, name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data->>'name', candidate))
  on conflict (id) do update set updated_at = now();
  return new;
end;
$$;
revoke all on function public.handle_new_user_profile() from public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user_profile();

-- Busca por nome ou username sem expor e-mails.
create or replace function public.search_user_directory(search_term text)
returns table(id uuid, username text, name text)
language sql stable security definer set search_path = public
as $$
  select p.id, p.username, p.name
  from public.profiles p
  where auth.uid() is not null
    and p.id <> auth.uid()
    and (p.username ilike '%' || search_term || '%' or coalesce(p.name, '') ilike '%' || search_term || '%')
  order by lower(coalesce(p.name, p.username)), lower(p.username)
  limit 20;
$$;
revoke all on function public.search_user_directory(text) from public;
grant execute on function public.search_user_directory(text) to authenticated;
grant usage on schema public to authenticated;

-- =========================
-- AMIZADES E SOLICITAÇÕES
-- =========================
create table if not exists public.friendships (
  user_id uuid not null references auth.users(id) on delete cascade,
  friend_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
create index if not exists friendships_friend_id_idx on public.friendships (friend_id);
alter table public.friendships enable row level security;

drop policy if exists "Users can view their friendships" on public.friendships;
create policy "Users can view their friendships" on public.friendships for select to authenticated using (auth.uid() = user_id);
drop policy if exists "Users can create their friendships" on public.friendships;
create policy "Users can create their friendships" on public.friendships for insert to authenticated with check (auth.uid() = user_id);
drop policy if exists "Users can delete their friendships" on public.friendships;
create policy "Users can delete their friendships" on public.friendships for delete to authenticated using (auth.uid() = user_id);

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted','declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (sender_id <> receiver_id)
);
create index if not exists friend_requests_receiver_status_idx on public.friend_requests (receiver_id, status, created_at desc);
create unique index if not exists friend_requests_pending_pair_idx on public.friend_requests (least(sender_id, receiver_id), greatest(sender_id, receiver_id)) where status = 'pending';
alter table public.friend_requests enable row level security;

drop policy if exists "Users can view friend requests" on public.friend_requests;
create policy "Users can view friend requests" on public.friend_requests for select to authenticated using (auth.uid() = sender_id or auth.uid() = receiver_id);
drop policy if exists "Users can send friend requests" on public.friend_requests;
create policy "Users can send friend requests" on public.friend_requests for insert to authenticated with check (auth.uid() = sender_id);
drop policy if exists "Users can update friend requests" on public.friend_requests;
create policy "Users can update friend requests" on public.friend_requests for update to authenticated using (auth.uid() = sender_id or auth.uid() = receiver_id) with check (auth.uid() = sender_id or auth.uid() = receiver_id);

create or replace function public.send_friend_request(target_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  existing_pending uuid;
  existing_friend boolean;
  new_request public.friend_requests;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
  if target_user_id = auth.uid() then raise exception 'Você não pode adicionar a si mesmo'; end if;
  if not exists (select 1 from auth.users where id = target_user_id) then raise exception 'Usuário não encontrado'; end if;
  select exists (select 1 from public.friendships where user_id = auth.uid() and friend_id = target_user_id)
      or exists (select 1 from public.friendships where user_id = target_user_id and friend_id = auth.uid()) into existing_friend;
  if existing_friend then return jsonb_build_object('status','already_friends'); end if;
  select id into existing_pending from public.friend_requests
    where status='pending' and ((sender_id=auth.uid() and receiver_id=target_user_id) or (sender_id=target_user_id and receiver_id=auth.uid()))
    limit 1;
  if existing_pending is not null then return jsonb_build_object('status','already_pending','id',existing_pending); end if;
  insert into public.friend_requests(sender_id, receiver_id) values(auth.uid(), target_user_id) returning * into new_request;
  return jsonb_build_object('status','sent','id',new_request.id);
exception when unique_violation then
  return jsonb_build_object('status','already_pending');
end;
$$;
revoke all on function public.send_friend_request(uuid) from public;
grant execute on function public.send_friend_request(uuid) to authenticated;

create or replace function public.respond_friend_request(request_id uuid, accept_request boolean)
returns jsonb language plpgsql security definer set search_path = public
as $$
declare
  req public.friend_requests;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
  select * into req from public.friend_requests where id=request_id and receiver_id=auth.uid() and status='pending' for update;
  if not found then raise exception 'Solicitação não encontrada ou já processada'; end if;
  if accept_request then
    insert into public.friendships(user_id, friend_id) values(req.sender_id, req.receiver_id) on conflict do nothing;
    insert into public.friendships(user_id, friend_id) values(req.receiver_id, req.sender_id) on conflict do nothing;
    update public.friend_requests set status='accepted', updated_at=now() where id=req.id;
    return jsonb_build_object('status','accepted');
  else
    update public.friend_requests set status='declined', updated_at=now() where id=req.id;
    return jsonb_build_object('status','declined');
  end if;
end;
$$;
revoke all on function public.respond_friend_request(uuid, boolean) from public;
grant execute on function public.respond_friend_request(uuid, boolean) to authenticated;

-- =========================
-- GRUPOS
-- =========================
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  description text default '',
  photo text default '',
  ai_enabled boolean not null default false,
  created_at timestamptz not null default now()
);
create index if not exists groups_owner_id_idx on public.groups (owner_id);
alter table public.groups enable row level security;

create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('admin','member')),
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
alter table public.group_members add column if not exists role text not null default 'member';
create index if not exists group_members_user_id_idx on public.group_members (user_id);
alter table public.group_members enable row level security;

create or replace function public.is_group_member(target_group uuid)
returns boolean language sql security definer set search_path = public
as $$ select exists(select 1 from public.group_members where group_id=target_group and user_id=auth.uid()); $$;
revoke all on function public.is_group_member(uuid) from public;
grant execute on function public.is_group_member(uuid) to authenticated;

drop policy if exists "Members can view groups" on public.groups;
create policy "Members can view groups" on public.groups for select to authenticated using (auth.uid() = owner_id or public.is_group_member(id));
drop policy if exists "Users can create groups" on public.groups;
create policy "Users can create groups" on public.groups for insert to authenticated with check (auth.uid() = owner_id);
drop policy if exists "Owners can update groups" on public.groups;
create policy "Owners can update groups" on public.groups for update to authenticated using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

drop policy if exists "Members can view membership" on public.group_members;
create policy "Members can view membership" on public.group_members for select to authenticated using (user_id=auth.uid() or exists(select 1 from public.groups g where g.id=group_members.group_id and g.owner_id=auth.uid()) or public.is_group_member(group_id));
drop policy if exists "Owners can add members" on public.group_members;
create policy "Owners can add members" on public.group_members for insert to authenticated with check (exists(select 1 from public.groups g where g.id=group_members.group_id and g.owner_id=auth.uid()));
drop policy if exists "Owners can remove members" on public.group_members;
create policy "Owners can remove members" on public.group_members for delete to authenticated using (user_id=auth.uid() or exists(select 1 from public.groups g where g.id=group_members.group_id and g.owner_id=auth.uid()));

-- Cria grupo + administrador + membros selecionados em uma única transação.
create or replace function public.create_group_with_members(group_name text, member_ids uuid[] default '{}')
returns public.groups language plpgsql security definer set search_path = public
as $$
declare
  new_group public.groups;
  member_id uuid;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
  if trim(coalesce(group_name,'')) = '' then raise exception 'Nome do grupo obrigatório'; end if;
  insert into public.groups(owner_id, name) values(auth.uid(), trim(group_name)) returning * into new_group;
  insert into public.group_members(group_id, user_id, role) values(new_group.id, auth.uid(), 'admin') on conflict do nothing;
  if member_ids is not null then
    foreach member_id in array member_ids loop
      if member_id is not null and member_id <> auth.uid() then
        insert into public.group_members(group_id, user_id, role) values(new_group.id, member_id, 'member') on conflict do nothing;
      end if;
    end loop;
  end if;
  return new_group;
end;
$$;
revoke all on function public.create_group_with_members(text, uuid[]) from public;
grant execute on function public.create_group_with_members(text, uuid[]) to authenticated;

create or replace function public.add_group_members(target_group_id uuid, member_ids uuid[])
returns integer language plpgsql security definer set search_path = public
as $$
declare
  member_id uuid;
  added integer := 0;
begin
  if auth.uid() is null then raise exception 'Usuário não autenticado'; end if;
  if not exists(select 1 from public.groups where id=target_group_id and owner_id=auth.uid()) then raise exception 'Somente o administrador do grupo pode adicionar membros'; end if;
  if member_ids is not null then
    foreach member_id in array member_ids loop
      if member_id is not null and exists(select 1 from auth.users where id=member_id) then
        insert into public.group_members(group_id,user_id,role) values(target_group_id,member_id,'member') on conflict do nothing;
        if found then added := added + 1; end if;
      end if;
    end loop;
  end if;
  return added;
end;
$$;
revoke all on function public.add_group_members(uuid, uuid[]) from public;
grant execute on function public.add_group_members(uuid, uuid[]) to authenticated;

-- Corrige administradores de grupos já existentes: o dono passa a ser admin/membro.
insert into public.group_members(group_id,user_id,role)
select g.id,g.owner_id,'admin' from public.groups g
on conflict (group_id,user_id) do update set role='admin';

-- =========================
-- MENSAGENS
-- =========================
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null,
  content text not null,
  is_ai boolean not null default false,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
create index if not exists messages_group_created_idx on public.messages (group_id, created_at);
create index if not exists messages_author_id_idx on public.messages (author_id);
alter table public.messages enable row level security;

drop policy if exists "Members can view messages" on public.messages;
create policy "Members can view messages" on public.messages for select to authenticated using (exists(select 1 from public.groups g where g.id=messages.group_id and (g.owner_id=auth.uid() or public.is_group_member(g.id))));
drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages" on public.messages for insert to authenticated with check (auth.uid()=author_id and exists(select 1 from public.groups g where g.id=messages.group_id and (g.owner_id=auth.uid() or public.is_group_member(g.id))));
drop policy if exists "Authors can edit messages" on public.messages;
create policy "Authors can edit messages" on public.messages for update to authenticated using (auth.uid()=author_id) with check (auth.uid()=author_id);

-- Realtime: não falha se alguma tabela já estiver publicada.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='messages') then alter publication supabase_realtime add table public.messages; end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='friend_requests') then alter publication supabase_realtime add table public.friend_requests; end if;
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='friendships') then alter publication supabase_realtime add table public.friendships; end if;
exception when undefined_object then null;
end $$;


-- Atualiza imediatamente o schema cache do PostgREST/Supabase.
notify pgrst, 'reload schema';
