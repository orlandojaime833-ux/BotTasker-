-- ═══════════════════════════════════════════════════════════════
--  TaskMarket — Schema Supabase
--  Executar no SQL Editor do projecto lozfhyublilhlkwykfnx
-- ═══════════════════════════════════════════════════════════════

-- ── Extensões ───────────────────────────────────────────────────
create extension if not exists "pgcrypto";

-- ════════════════════════════════════════════════════════════════
--  TABELA: users
-- ════════════════════════════════════════════════════════════════
create table if not exists users (
  id              bigserial        primary key,
  telegram_id     text             unique not null,
  username        text,
  ton_balance     numeric(18,6)    not null default 0,
  referral_count  int              not null default 0,
  referred_by     bigint           references users(id) on delete set null,
  created_at      timestamptz      not null default now()
);

comment on table  users                is 'Utilizadores registados via Telegram';
comment on column users.telegram_id    is 'ID único do utilizador no Telegram';
comment on column users.ton_balance    is 'Saldo disponível em TONCOIN';
comment on column users.referral_count is 'Número de referências bem-sucedidas';
comment on column users.referred_by    is 'ID interno do utilizador que referiu este';

create index if not exists idx_users_telegram_id on users(telegram_id);
create index if not exists idx_users_referred_by on users(referred_by);

-- ════════════════════════════════════════════════════════════════
--  TABELA: tasks
-- ════════════════════════════════════════════════════════════════
create table if not exists tasks (
  id            bigserial     primary key,
  advertiser_id bigint        not null references users(id) on delete cascade,
  executor_id   bigint        references users(id) on delete set null,
  title         text          not null,
  description   text,
  reward        numeric(18,6) not null check (reward > 0),
  deadline      text,
  status        text          not null default 'open'
                              check (status in ('open','in_progress','pending_review','completed','cancelled')),
  created_at    timestamptz   not null default now(),
  updated_at    timestamptz   not null default now()
);

comment on table  tasks               is 'Tarefas publicadas no marketplace';
comment on column tasks.advertiser_id is 'Utilizador que criou e financia a tarefa';
comment on column tasks.executor_id   is 'Utilizador que aceitou executar a tarefa';
comment on column tasks.reward        is 'Recompensa em TONCOIN (em escrow enquanto open/in_progress)';
comment on column tasks.status        is 'open | in_progress | pending_review | completed | cancelled';

create index if not exists idx_tasks_status        on tasks(status);
create index if not exists idx_tasks_advertiser_id on tasks(advertiser_id);
create index if not exists idx_tasks_executor_id   on tasks(executor_id);

-- Auto-actualizar updated_at
create or replace function set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists trg_tasks_updated_at on tasks;
create trigger trg_tasks_updated_at
  before update on tasks
  for each row execute function set_updated_at();

-- ════════════════════════════════════════════════════════════════
--  TABELA: deposit_invoices
-- ════════════════════════════════════════════════════════════════
create table if not exists deposit_invoices (
  id          bigserial     primary key,
  user_id     bigint        not null references users(id) on delete cascade,
  invoice_id  text          unique not null,
  amount_ton  numeric(18,6) not null check (amount_ton > 0),
  status      text          not null default 'pending'
                            check (status in ('pending','paid','expired')),
  paid_at     timestamptz,
  created_at  timestamptz   not null default now()
);

comment on table  deposit_invoices            is 'Invoices de depósito criadas via xRocket';
comment on column deposit_invoices.invoice_id is 'ID da invoice no sistema xRocket';
comment on column deposit_invoices.status     is 'pending | paid | expired';

create index if not exists idx_deposit_invoices_user_id   on deposit_invoices(user_id);
create index if not exists idx_deposit_invoices_status    on deposit_invoices(status);
create index if not exists idx_deposit_invoices_invoice_id on deposit_invoices(invoice_id);

-- ════════════════════════════════════════════════════════════════
--  TABELA: transactions
-- ════════════════════════════════════════════════════════════════
create table if not exists transactions (
  id         bigserial     primary key,
  user_id    bigint        not null references users(id) on delete cascade,
  type       text          not null
                           check (type in ('deposit','payment','receipt','ton_withdrawal')),
  amount     numeric(18,6) not null check (amount > 0),
  task_id    bigint        references tasks(id) on delete set null,
  note       text,
  created_at timestamptz   not null default now()
);

comment on table  transactions        is 'Histórico de movimentos de saldo';
comment on column transactions.type   is 'deposit=entrada xRocket | payment=escrow tarefa | receipt=pagamento recebido | ton_withdrawal=saque';
comment on column transactions.amount is 'Valor em TONCOIN';

create index if not exists idx_transactions_user_id on transactions(user_id);
create index if not exists idx_transactions_task_id on transactions(task_id);
create index if not exists idx_transactions_type    on transactions(type);

-- ════════════════════════════════════════════════════════════════
--  TABELA: referrals
-- ════════════════════════════════════════════════════════════════
create table if not exists referrals (
  id                bigserial     primary key,
  referrer_id       bigint        not null references users(id) on delete cascade,
  referred_telegram text          not null,
  ton_credited      numeric(18,6) not null default 0.01,
  created_at        timestamptz   not null default now()
);

comment on table  referrals                   is 'Registo de referências entre utilizadores';
comment on column referrals.referrer_id       is 'Utilizador que fez a referência';
comment on column referrals.referred_telegram is 'Telegram ID do novo utilizador referido';
comment on column referrals.ton_credited      is 'TON creditados ao referrer';

create index if not exists idx_referrals_referrer_id on referrals(referrer_id);

-- ════════════════════════════════════════════════════════════════
--  FUNÇÃO: pay_executor
--  Chamada pelo bot em task_approve — transfere reward do escrow
--  para o saldo do executor e regista a transacção.
-- ════════════════════════════════════════════════════════════════
create or replace function pay_executor(task_id bigint)
returns void
language plpgsql
security definer
as $$
declare
  t tasks%rowtype;
begin
  -- Carrega a tarefa e bloqueia a linha para evitar double-pay
  select * into t from tasks where id = task_id for update;

  if not found then
    raise exception 'Tarefa % não encontrada', task_id;
  end if;

  if t.status <> 'pending_review' then
    raise exception 'Tarefa % não está em pending_review (estado actual: %)', task_id, t.status;
  end if;

  if t.executor_id is null then
    raise exception 'Tarefa % não tem executor definido', task_id;
  end if;

  -- Credita o saldo do executor
  update users
     set ton_balance = ton_balance + t.reward
   where id = t.executor_id;

  -- Regista a transacção
  insert into transactions(user_id, type, amount, task_id, note)
  values (t.executor_id, 'receipt', t.reward, task_id, 'Pagamento por tarefa concluída');
end;
$$;

comment on function pay_executor(bigint) is
  'Paga o executor de uma tarefa em pending_review. Usa FOR UPDATE para evitar double-pay.';

-- ════════════════════════════════════════════════════════════════
--  ROW LEVEL SECURITY (RLS)
--  O bot usa a service_role key → bypassa RLS automaticamente.
--  Activar RLS protege contra acessos directos não autorizados.
-- ════════════════════════════════════════════════════════════════
alter table users              enable row level security;
alter table tasks              enable row level security;
alter table deposit_invoices   enable row level security;
alter table transactions       enable row level security;
alter table referrals          enable row level security;

-- Nenhuma política pública — apenas service_role (bot) tem acesso.
-- Se precisares de um painel web com auth do Supabase, adiciona
-- políticas específicas aqui.
