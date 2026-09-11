-- Ottoni - SQL final para Supabase
-- Execute no SQL Editor do seu projeto.
-- Este SQL cria perfis automaticamente após o cadastro e permite a busca de usuários.

create extension if not exists pgcrypto;

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique not null,
  name text,
  topic text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.profiles add column if not exists username text;
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

-- Diretório público apenas com dados de identificação do usuário, sem senha/token.
drop view if exists public.user_directory;
create view public.user_directory as
select id, username, name
from public.profiles;
grant select on public.user_directory to authenticated;

-- Cria o perfil automaticamente quando um novo usuário entra no Auth.
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
  if base_username = '' then
    base_username := 'usuario';
  end if;

  candidate := base_username;
  suffix := '_' || substr(replace(new.id::text, '-', ''), 1, 6);

  if exists (select 1 from public.profiles where username = candidate) then
    candidate := left(base_username, 33) || suffix;
  end if;

  insert into public.profiles (id, username, name)
  values (
    new.id,
    candidate,
    coalesce(new.raw_user_meta_data->>'name', candidate)
  )
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
create unique index if not exists friend_requests_pending_key on public.friend_requests (sender_id, receiver_id) where status = 'pending';
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
using (auth.uid() = receiver_id or auth.uid() = sender_id)
with check (auth.uid() = receiver_id or auth.uid() = sender_id);

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

insert into storage.buckets (id, name, public)
values ('ottoni-media', 'ottoni-media', true)
on conflict (id) do nothing;

drop policy if exists "Authenticated users can upload Ottoni media" on storage.objects;
create policy "Authenticated users can upload Ottoni media"
on storage.objects for insert to authenticated
with check (bucket_id = 'ottoni-media' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "Anyone can view Ottoni media" on storage.objects;
create policy "Anyone can view Ottoni media"
on storage.objects for select to public
using (bucket_id = 'ottoni-media');

do $$
begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null;
end $$;

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
    select 1 from public.group_members
    where group_id = target_group and user_id = auth.uid()
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
  or exists (select 1 from public.groups where groups.id = group_members.group_id and groups.owner_id = auth.uid())
  or public.is_group_member(group_id)
);

drop policy if exists "Owners can add members" on public.group_members;
create policy "Owners can add members"
on public.group_members for insert to authenticated
with check (exists (select 1 from public.groups where groups.id = group_members.group_id and groups.owner_id = auth.uid()));

drop policy if exists "Owners can remove members" on public.group_members;
create policy "Owners can remove members"
on public.group_members for delete to authenticated
using (
  user_id = auth.uid()
  or exists (select 1 from public.groups where groups.id = group_members.group_id and groups.owner_id = auth.uid())
);

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
create index if not exists messages_group_created_idx on public.messages (group_id, created_at);
create index if not exists messages_author_id_idx on public.messages (author_id);
alter table public.messages enable row level security;

drop policy if exists "Members can view messages" on public.messages;
create policy "Members can view messages"
on public.messages for select to authenticated
using (exists (
  select 1 from public.groups
  where groups.id = messages.group_id
    and (groups.owner_id = auth.uid() or public.is_group_member(groups.id))
));

drop policy if exists "Members can send messages" on public.messages;
create policy "Members can send messages"
on public.messages for insert to authenticated
with check ((
  (is_ai = false and auth.uid() = author_id)
  or
  (is_ai = true and author_id is null)
) and exists (
  select 1 from public.groups
  where groups.id = messages.group_id
    and (groups.owner_id = auth.uid() or public.is_group_member(groups.id))
));

drop policy if exists "Authors can edit messages" on public.messages;
create policy "Authors can edit messages"
on public.messages for update to authenticated
using (auth.uid() = author_id)
with check (auth.uid() = author_id);
