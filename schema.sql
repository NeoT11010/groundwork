-- ================================================================
-- GROUNDWORK — Supabase Schema
-- Run this in your Supabase project: SQL Editor → New query → Run
-- ================================================================

-- Enable UUID extension
create extension if not exists "uuid-ossp";

-- ----------------------------------------------------------------
-- COMPANIES
-- Each authenticated user belongs to one company.
-- ----------------------------------------------------------------
create table if not exists public.companies (
  id            uuid primary key default uuid_generate_v4(),
  name          text not null,
  trade         text,                        -- e.g. 'groundworks', 'roofing'
  employees     int,
  turnover_band text,                        -- e.g. '250k-1m'
  plan          text not null default 'essentials', -- essentials | growth | scale
  trial_ends_at timestamptz default (now() + interval '30 days'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------
-- PROFILES
-- One profile per auth.users row, linked to a company.
-- ----------------------------------------------------------------
create table if not exists public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  full_name     text,
  company_id    uuid references public.companies(id) on delete set null,
  role          text not null default 'admin',  -- admin | member
  created_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------
-- MONTHLY UPDATES
-- The core data payload — submitted once per month per company.
-- ----------------------------------------------------------------
create table if not exists public.monthly_updates (
  id            uuid primary key default uuid_generate_v4(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  period_month  int  not null check (period_month between 1 and 12),
  period_year   int  not null,
  -- Plant hours (JSON: [{ plant_id, hours }])
  plant_hours   jsonb not null default '[]',
  -- Vehicle mileage (JSON: [{ vehicle_id, miles }])
  vehicle_miles jsonb not null default '[]',
  -- Waste tonnage
  waste_general_t  numeric(8,2) default 0,
  waste_recycled_t numeric(8,2) default 0,
  waste_hazard_t   numeric(8,2) default 0,
  -- Utilities
  electricity_kwh  numeric(10,2) default 0,
  gas_kwh          numeric(10,2) default 0,
  water_m3         numeric(10,2) default 0,
  -- Computed outputs (stored after scoring engine runs)
  score            numeric(5,2),
  co2e_total_t     numeric(10,4),
  submitted_by  uuid references auth.users(id),
  created_at    timestamptz not null default now(),
  unique (company_id, period_year, period_month)
);

-- ----------------------------------------------------------------
-- CERTIFICATIONS
-- Boolean flags for each cert held by the company.
-- ----------------------------------------------------------------
create table if not exists public.certifications (
  id            uuid primary key default uuid_generate_v4(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  cert_key      text not null,   -- e.g. 'iso14001', 'constructionline', 'chas'
  status        text not null default 'none', -- 'none' | 'in_progress' | 'held'
  held_since    date,
  expires_at    date,
  updated_at    timestamptz not null default now(),
  unique (company_id, cert_key)
);

-- ----------------------------------------------------------------
-- PLANT FLEET
-- Machines / equipment registered to a company.
-- ----------------------------------------------------------------
create table if not exists public.plant_fleet (
  id            uuid primary key default uuid_generate_v4(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  name          text not null,
  category      text,             -- e.g. 'excavator', 'dumper'
  fuel_type     text default 'diesel',
  ef_kg_per_hr  numeric(8,4),    -- kg CO2e per engine hour (DEFRA)
  active        bool default true,
  created_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------
-- VEHICLES
-- Road vehicles registered to a company.
-- ----------------------------------------------------------------
create table if not exists public.vehicles (
  id            uuid primary key default uuid_generate_v4(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  name          text not null,
  fuel_type     text default 'diesel',   -- diesel | petrol | electric | hvo
  ef_kg_per_mile numeric(8,4),          -- kg CO2e per mile (DEFRA)
  active        bool default true,
  created_at    timestamptz not null default now()
);

-- ----------------------------------------------------------------
-- TENDER APPLICATIONS
-- Track tenders a company has applied for.
-- ----------------------------------------------------------------
create table if not exists public.tender_applications (
  id            uuid primary key default uuid_generate_v4(),
  company_id    uuid not null references public.companies(id) on delete cascade,
  tender_ref    text,
  client        text,
  contract_value numeric(12,2),
  status        text default 'preparing',  -- preparing | submitted | shortlisted | won | lost
  deadline      date,
  notes         text,
  created_at    timestamptz not null default now()
);

-- ================================================================
-- ROW LEVEL SECURITY
-- Every table is locked to the authenticated user's company.
-- ================================================================

alter table public.companies             enable row level security;
alter table public.profiles              enable row level security;
alter table public.monthly_updates       enable row level security;
alter table public.certifications        enable row level security;
alter table public.plant_fleet           enable row level security;
alter table public.vehicles              enable row level security;
alter table public.tender_applications   enable row level security;

-- Helper: get the company_id for the current authenticated user
create or replace function public.my_company_id()
returns uuid language sql security definer stable as $$
  select company_id from public.profiles where id = auth.uid()
$$;

-- PROFILES: users can only read/update their own row
create policy "profiles: own row" on public.profiles
  for all using (id = auth.uid());

-- COMPANIES: users can read/update their own company
create policy "companies: own company" on public.companies
  for all using (id = public.my_company_id());

-- MONTHLY_UPDATES: users can CRUD their own company's updates
create policy "monthly_updates: own company" on public.monthly_updates
  for all using (company_id = public.my_company_id());

-- CERTIFICATIONS
create policy "certifications: own company" on public.certifications
  for all using (company_id = public.my_company_id());

-- PLANT_FLEET
create policy "plant_fleet: own company" on public.plant_fleet
  for all using (company_id = public.my_company_id());

-- VEHICLES
create policy "vehicles: own company" on public.vehicles
  for all using (company_id = public.my_company_id());

-- TENDER_APPLICATIONS
create policy "tender_applications: own company" on public.tender_applications
  for all using (company_id = public.my_company_id());

-- ================================================================
-- TRIGGERS
-- Auto-create a profile row when a new user signs up.
-- ================================================================
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer as $$
declare
  new_company_id uuid;
begin
  -- Create company from user metadata
  insert into public.companies (name, plan)
  values (
    coalesce(new.raw_user_meta_data->>'company_name', 'My Company'),
    coalesce(new.raw_user_meta_data->>'plan', 'essentials')
  )
  returning id into new_company_id;

  -- Create profile linked to company
  insert into public.profiles (id, full_name, company_id, role)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    new_company_id,
    'admin'
  );

  return new;
end;
$$;

create or replace trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ================================================================
-- DONE
-- After running this, go to your Supabase project Settings → API
-- and copy the Project URL and anon public key into index.html:
--   const SUPABASE_URL  = 'https://xxxx.supabase.co';
--   const SUPABASE_ANON = 'eyJ...';
-- ================================================================
