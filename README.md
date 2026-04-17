# TaskMarket Bot

Bot Telegram para marketplace de tarefas pagas em TON via xRocket.  
Ligação directa ao Supabase — sem camadas intermédias.

## Stack

- **Node.js** + `node-telegram-bot-api`
- **Supabase** (PostgreSQL) — acesso directo com service role key
- **xRocket** — pagamentos em TONCOIN
- **Render** — hosting (webhook mode)

## Configuração rápida

### 1. Clonar o repositório

```bash
git clone https://github.com/SEU_USER/taskmarket-bot.git
cd taskmarket-bot
npm install
```

### 2. Variáveis de ambiente

Copia `.env.example` para `.env` e preenche os valores:

```bash
cp .env.example .env
```

| Variável | Descrição |
|---|---|
| `BOT_TOKEN` | Token do BotFather |
| `SUPABASE_URL` | URL do projecto Supabase |
| `SUPABASE_SERVICE_KEY` | Service role key do Supabase |
| `XROCKET_TOKEN` | API key do xRocket |
| `WEBHOOK_URL` | URL público do servidor (ex: Render) |
| `PORT` | Porta HTTP (default: 3000) |

> ⚠️ **Nunca** faças commit do ficheiro `.env` nem exponhas as chaves em código.

### 3. Correr localmente

```bash
node bot.js
```

Para expor localmente usar [ngrok](https://ngrok.com/):

```bash
ngrok http 3000
# Copia o URL https:// gerado e define como WEBHOOK_URL no .env
```

## Deploy no Render

1. Cria um novo **Web Service** no [Render](https://render.com)
2. Liga ao repositório GitHub
3. Define as variáveis de ambiente no painel do Render
4. O `RENDER_EXTERNAL_URL` é definido automaticamente — o bot usa-o como `WEBHOOK_URL` se não definires outro
5. Start command: `node bot.js`

## Tabelas Supabase necessárias

```sql
-- Utilizadores
create table users (
  id              bigserial primary key,
  telegram_id     text unique not null,
  username        text,
  ton_balance     numeric default 0,
  referral_count  int default 0,
  referred_by     bigint references users(id)
);

-- Tarefas
create table tasks (
  id            bigserial primary key,
  advertiser_id bigint references users(id),
  executor_id   bigint references users(id),
  title         text not null,
  description   text,
  reward        numeric not null,
  deadline      text,
  status        text default 'open',
  created_at    timestamptz default now()
);

-- Invoices de depósito
create table deposit_invoices (
  id          bigserial primary key,
  user_id     bigint references users(id),
  invoice_id  text unique not null,
  amount_ton  numeric not null,
  status      text default 'pending',
  paid_at     timestamptz,
  created_at  timestamptz default now()
);

-- Transacções
create table transactions (
  id         bigserial primary key,
  user_id    bigint references users(id),
  type       text,
  amount     numeric,
  task_id    bigint references tasks(id),
  note       text,
  created_at timestamptz default now()
);

-- Referências
create table referrals (
  id                bigserial primary key,
  referrer_id       bigint references users(id),
  referred_telegram text,
  ton_credited      numeric,
  created_at        timestamptz default now()
);

-- Função para pagar executor (chamada em task_approve)
create or replace function pay_executor(task_id bigint)
returns void language plpgsql as $$
declare
  t tasks%rowtype;
begin
  select * into t from tasks where id = task_id;
  update users set ton_balance = ton_balance + t.reward where id = t.executor_id;
  insert into transactions(user_id, type, amount, task_id, note)
  values (t.executor_id, 'receipt', t.reward, task_id, 'Pagamento por tarefa concluída');
end;
$$;
```

## Segurança

- Todas as credenciais são lidas exclusivamente via variáveis de ambiente
- O ficheiro `.env` está no `.gitignore`
- Nunca usar a `anon key` do Supabase no bot — usar sempre a `service_role key`

## Licença

MIT
