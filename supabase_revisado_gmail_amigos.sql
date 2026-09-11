-- Ottoni - SQL completo para Supabase
-- Pode ser executado novamente: as tabelas, políticas e funções são idempotentes.
-- Execute este arquivo inteiro no SQL Editor do mesmo projeto Supabase.

create extension if not exists pgcrypto;

-- ============================================================
-- PERFIS / DIRETÓRIO DE USUÁRIOS
-- ============================================================
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
create unique index if not exists profiles_username_key on public.profiles (username);
create index if not exists profiles_name_idx on public.profiles (lower(name));

alter table public.profiles enable row level security;

drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
on public.profiles for select to authenticated
using (auth.uid() = id);

drop policy if exists "Users can create own profile" on public.profiles;
create policy "Users can create own profile"
on public.profiles for insert to authenticated
with check (auth.uid() = id);

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
on public.profiles for update to authenticated
using (auth.uid() = id)
with check (auth.uid() = id);

drop view if exists public.user_directory;
create view public.user_directory as
select id, username, name
from public.profiles;
grant select on public.user_directory to authenticated;

create or replace function public.handle_new_user_profile()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  base_username text;
  candidate text;
  suffix text;
begin
  base_username := lower(coalesce(
    new.raw_user_meta_data->>'username',
    new.raw_user_meta_data->>'name',
    split_part(coalesce(new.email, ''), '@', 1),
    'usuario'
  ));
  base_username := regexp_replace(base_username, '[^a-z0-9._-]', '', 'g');
  base_username := left(base_username, 40);
  if base_username = '' then base_username := 'usuario'; end if;

  candidate := base_username;
  suffix := '_' || substr(replace(new.id::text, '-', ''), 1, 6);

  if exists (select 1 from public.profiles where username = candidate) then
    candidate := left(base_username, 33) || suffix;
  end if;

  -- Evita falha de cadastro se o candidato de 6 caracteres também estiver ocupado.
  if exists (select 1 from public.profiles where username = candidate) then
    candidate := left(base_username, 25) || '_' || substr(replace(new.id::text, '-', ''), 1, 14);
  end if;

  insert into public.profiles (id, username, name)
  values (new.id, candidate, coalesce(new.raw_user_meta_data->>'name', candidate))
  on conflict (id) do update
  set username = excluded.username,
      name = coalesce(public.profiles.name, excluded.name),
      updated_at = now();

  return new;
end;
$$;

revoke all on function public.handle_new_user_profile() from public;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user_profile();

-- ============================================================
-- AMIZADES / SOLICITAÇÕES / BLOQUEIOS
-- ============================================================
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
create policy "Users can view their friendships"
on public.friendships for select to authenticated
using (auth.uid() = user_id);

drop policy if exists "Users can create their friendships" on public.friendships;
create policy "Users can create their friendships"
on public.friendships for insert to authenticated
with check (auth.uid() = user_id);

drop policy if exists "Users can delete their friendships" on public.friendships;
create policy "Users can delete their friendships"
on public.friendships for delete to authenticated
using (auth.uid() = user_id);

create table if not exists public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references auth.users(id) on delete cascade,
  receiver_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (sender_id <> receiver_id)
);
create index if not exists friend_requests_receiver_idx on public.friend_requests (receiver_id, status);
create index if not exists friend_requests_sender_idx on public.friend_requests (sender_id, status);
create unique index if not exists friend_requests_pending_key
on public.friend_requests (sender_id, receiver_id)
where status = 'pending';
alter table public.friend_requests enable row level security;

drop policy if exists "Users can view their friend requests" on public.friend_requests;
create policy "Users can view their friend requests"
on public.friend_requests for select to authenticated
using (auth.uid() = sender_id or auth.uid() = receiver_id);

drop policy if exists "Users can send friend requests" on public.friend_requests;
create policy "Users can send friend requests"
on public.friend_requests for insert to authenticated
with check (auth.uid() = sender_id);

drop policy if exists "Users can update received friend requests" on public.friend_requests;
create policy "Users can update received friend requests"
on public.friend_requests for update to authenticated
using (auth.uid() = receiver_id)
with check (auth.uid() = receiver_id);

create table if not exists public.blocked_users (
  user_id uuid not null references auth.users(id) on delete cascade,
  blocked_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, blocked_id),
  check (user_id <> blocked_id)
);
alter table public.blocked_users enable row level security;

drop policy if exists "Users can manage blocked users" on public.blocked_users;
create policy "Users can manage blocked users"
on public.blocked_users for all to authenticated
using (auth.uid() = user_id)
with check (auth.uid() = user_id);

-- ============================================================
-- GRUPOS
-- ============================================================
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
  created_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user_id_idx on public.group_members (user_id);
alter table public.group_members enable row level security;

create or replace function public.is_group_member(target_group uuid)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.group_members
    where group_id = target_group
      and user_id = auth.uid()
  );
$$;
revoke all on function public.is_group_member(uuid) from public;
grant execute on function public.is_group_member(uuid) to authenticated;

drop policy if exists "Members can view groups" on public.groups;
create policy "Members can view groups"
on public.groups for select to authenticated
using (auth.uid() = owner_id or public.is_group_member(id));

drop policy if exists "Users can create groups" on public.groups;
create policy "Users can create groups"
on public.groups for insert to authenticated
with check (auth.uid() = owner_id);

drop policy if exists "Owners can update groups" on public.groups;
create policy "Owners can update groups"
on public.groups for update to authenticated
using (auth.uid() = owner_id)
with check (auth.uid() = owner_id);

drop policy if exists "Members can view membership" on public.group_members;
create policy "Members can view membership"
on public.group_members for select to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.groups
    where groups.id = group_members.group_id
      and groups.owner_id = auth.uid()
  )
  or public.is_group_member(group_id)
);

drop policy if exists "Owners can add members" on public.group_members;
create policy "Owners can add members"
on public.group_members for insert to authenticated
with check (
  exists (
    select 1 from public.groups
    where groups.id = group_members.group_id
      and groups.owner_id = auth.uid()
  )
);

drop policy if exists "Owners can remove members" on public.group_members;
create policy "Owners can remove members"
on public.group_members for delete to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1 from public.groups
    where groups.id = group_members.group_id
      and groups.owner_id = auth.uid()
  )
);

-- ============================================================
-- MENSAGENS
-- ============================================================
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups(id) on delete cascade,
  author_id uuid references auth.users(id) on delete set null,
  content text not null,
  reply_to_id uuid references public.messages(id) on delete set null,
  media_url text,
  media_type text,
  is_ai boolean not null default false,
  created_at timestamptz not null default now(),
  edited_at timestamptz
);
alter table public.messages add column if not exists reply_to_id uuid references public.messages(id) on delete set null;
alter table public.messages add column if not exists media_url text;
alter table public.messages add column if not exists media_type text;
alter table public.messages add column if not exists is_ai boolean not null default false;
alter table public.messages add column if not exists edited_at timestamptz;
create index if not exists messages_group_created_idx on public.messages (group_id, created_at);
create index if not exists messages_author_id_idx on public.messages (author_id);
alter table public.messages enable row level security;

drop policy if exists "Members can view messages" on public.messages;
create policy "Members can view messages"
on public.messages for select to authenticated
using (
  exists (
    select 1 from public.groups
    where groups.id = messages.group_id
      and (groups.owner_id = auth.uid() or public.is_group_member(groups.id))
  )
);

drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages"
on public.messages for insert to authenticated
with check (
  (
    (is_ai = false and auth.uid() = author_id)
    or
    (is_ai = true and author_id is null)
  )
  and exists (
    select 1 from public.groups
    where groups.id = messages.group_id
      and (groups.owner_id = auth.uid() or public.is_group_member(groups.id))
  )
);

drop policy if exists "Authors can edit messages" on public.messages;
create policy "Authors can edit messages"
on public.messages for update to authenticated
using (auth.uid() = author_id)
with check (auth.uid() = author_id);

-- ============================================================
-- STORAGE
-- ============================================================
insert into storage.buckets (id, name, public)
values ('ottoni-media', 'ottoni-media', true)
on conflict (id) do nothing;

drop policy if exists "Authenticated users can upload Ottoni media" on storage.objects;
create policy "Authenticated users can upload Ottoni media"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'ottoni-media'
  and (storage.foldername(name))[1] = auth.uid()::text
);

drop policy if exists "Anyone can view Ottoni media" on storage.objects;
create policy "Anyone can view Ottoni media"
on storage.objects for select to public
using (bucket_id = 'ottoni-media');

-- ============================================================
-- FUNÇÕES RPC: AMIGOS
-- ============================================================
create or replace function public.search_user_directory(
  search_term text,
  max_results integer default 8
)
returns table (id uuid, username text, name text)
language sql
security definer
set search_path = public
as $$
  select p.id, p.username, p.name
  from public.profiles p
  where auth.uid() is not null
    and (
      lower(coalesce(p.username, '')) like lower(trim(search_term)) || '%'
      or lower(coalesce(p.name, '')) like lower(trim(search_term)) || '%'
    )
  order by lower(coalesce(p.name, p.username)), lower(p.username)
  limit greatest(1, least(coalesce(max_results, 8), 20));
$$;
revoke all on function public.search_user_directory(text, integer) from public;
grant execute on function public.search_user_directory(text, integer) to authenticated;

create or replace function public.send_friend_request(target_user_id uuid)
returns public.friend_requests
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  result_request public.friend_requests;
begin
  if current_user_id is null then raise exception 'Você precisa estar autenticado.'; end if;
  if target_user_id is null or target_user_id = current_user_id then raise exception 'Usuário inválido.'; end if;
  if not exists (select 1 from auth.users where id = target_user_id) then raise exception 'Usuário não encontrado.'; end if;

  if exists (
    select 1 from public.friendships
    where (user_id = current_user_id and friend_id = target_user_id)
       or (user_id = target_user_id and friend_id = current_user_id)
  ) then raise exception 'Vocês já são amigos.'; end if;

  if exists (
    select 1 from public.friend_requests
    where status = 'pending'
      and (
        (sender_id = current_user_id and receiver_id = target_user_id)
        or (sender_id = target_user_id and receiver_id = current_user_id)
      )
  ) then raise exception 'Já existe uma solicitação pendente.'; end if;

  insert into public.friend_requests (sender_id, receiver_id)
  values (current_user_id, target_user_id)
  returning * into result_request;

  return result_request;
end;
$$;
revoke all on function public.send_friend_request(uuid) from public;
grant execute on function public.send_friend_request(uuid) to authenticated;

create or replace function public.accept_friend_request(request_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  request_row public.friend_requests;
begin
  if current_user_id is null then raise exception 'Você precisa estar autenticado.'; end if;

  select * into request_row
  from public.friend_requests
  where id = request_id
    and receiver_id = current_user_id
    and status = 'pending'
  for update;

  if not found then raise exception 'Solicitação não encontrada ou já respondida.'; end if;

  update public.friend_requests
  set status = 'accepted', updated_at = now()
  where id = request_id;

  insert into public.friendships (user_id, friend_id)
  values
    (request_row.sender_id, request_row.receiver_id),
    (request_row.receiver_id, request_row.sender_id)
  on conflict (user_id, friend_id) do nothing;

  return true;
end;
$$;
revoke all on function public.accept_friend_request(uuid) from public;
grant execute on function public.accept_friend_request(uuid) to authenticated;

-- ============================================================
-- FUNÇÕES RPC: GRUPOS
-- ============================================================
create or replace function public.create_group_for_user(
  group_name text,
  group_ai_enabled boolean default false
)
returns public.groups
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  created_group public.groups;
  clean_name text := trim(coalesce(group_name, ''));
begin
  if current_user_id is null then raise exception 'Você precisa estar autenticado.'; end if;
  if clean_name = '' then raise exception 'Informe o nome do grupo.'; end if;
  if char_length(clean_name) > 100 then raise exception 'O nome do grupo é muito grande.'; end if;

  insert into public.groups (owner_id, name, ai_enabled)
  values (current_user_id, clean_name, coalesce(group_ai_enabled, false))
  returning * into created_group;

  insert into public.group_members (group_id, user_id)
  values (created_group.id, current_user_id)
  on conflict (group_id, user_id) do nothing;

  return created_group;
end;
$$;
revoke all on function public.create_group_for_user(text, boolean) from public;
grant execute on function public.create_group_for_user(text, boolean) to authenticated;

create or replace function public.add_members_to_group(
  target_group_id uuid,
  member_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  current_user_id uuid := auth.uid();
  inserted_count integer := 0;
begin
  if current_user_id is null then raise exception 'Você precisa estar autenticado.'; end if;

  if not exists (
    select 1 from public.groups
    where id = target_group_id and owner_id = current_user_id
  ) then
    raise exception 'Somente o dono do grupo pode adicionar membros.';
  end if;

  if member_ids is null or cardinality(member_ids) = 0 then return 0; end if;

  insert into public.group_members (group_id, user_id)
  select target_group_id, member_id
  from unnest(member_ids) as member_id
  join auth.users u on u.id = member_id
  where member_id <> current_user_id
  on conflict (group_id, user_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;
revoke all on function public.add_members_to_group(uuid, uuid[]) from public;
grant execute on function public.add_members_to_group(uuid, uuid[]) to authenticated;

-- ============================================================
-- REALTIME: somente depois que public.messages existir
-- ============================================================
do $$
begin
  alter publication supabase_realtime add table public.messages;
exception
  when duplicate_object then null;
end $$;
