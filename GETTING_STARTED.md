# Getting Started

This guide assumes you have never touched this codebase and may not have written C# before.
Work through it in order. Nothing here touches AWS or costs money — everything runs on your laptop.

**Time needed:** about 45 minutes, most of it waiting for downloads.

---

## What you are setting up

You are setting up the **middleware** — the backend that sits between the Social Remit mobile app
and everything else (payout partners, SMS providers, identity checks).

Right now the mobile app makes its own decisions: it decides when to show the KYC screen, it
remembers the PIN, it knows which screen comes next. That is a problem, because anything the app
decides, a customer can tamper with, and anything stored only on the phone is lost when the phone
is lost. The middleware takes over every one of those decisions.

**At Step 1 (where you are now) there is no running service yet.** That is deliberate. What
exists is the *foundation*: the agreed shape of every API, every event, every error, and the
plumbing that all services will share. Building services before that foundation exists is how a
codebase becomes unmaintainable in month three.

---

## Step A — Install the tools

You need five things. Install them in this order.

### 1. .NET 10 SDK — the language and compiler

This is what compiles the C# code.

**macOS**
```bash
brew install --cask dotnet-sdk
```

**Windows** (PowerShell as Administrator)
```powershell
winget install Microsoft.DotNet.SDK.10
```

**Linux (Ubuntu/Debian)**
```bash
wget https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -O /tmp/ms.deb
sudo dpkg -i /tmp/ms.deb
sudo apt-get update && sudo apt-get install -y dotnet-sdk-10.0
```

**Check it worked:**
```bash
dotnet --version
```
You want something starting with `10.`. If you get "command not found", close and reopen your
terminal first — installers change your PATH and existing terminals do not see it.

---

### 2. Docker Desktop — runs the database on your laptop

We do not install PostgreSQL directly. Docker runs it in a container, so your machine stays clean
and everyone on the team gets an identical database.

- **macOS / Windows:** download from https://www.docker.com/products/docker-desktop and install.
- **Linux:**
  ```bash
  curl -fsSL https://get.docker.com | sudo sh
  sudo usermod -aG docker $USER   # then log out and back in
  ```

**Check it worked:**
```bash
docker --version
docker compose version
```

Docker Desktop must be **running** (you will see a whale icon in your menu bar or system tray).
Commands fail with "cannot connect to the Docker daemon" if it is not.

---

### 3. Node.js 22 — runs the contract linters

The tools that check our API definitions are written in JavaScript. You will not write any
JavaScript; you just need the runtime.

**macOS**
```bash
brew install node@22
```

**Windows**
```powershell
winget install OpenJS.NodeJS.LTS
```

**Linux**
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash -
sudo apt-get install -y nodejs
```

**Check it worked:**
```bash
node --version    # want v22.x
npm --version
```

---

### 4. Python 3.12 — runs the safety checks

Two of our checks (the one that stops passwords leaking into event logs, and the one that keeps
error codes in sync) are Python scripts.

macOS and most Linux systems already have it:
```bash
python3 --version
```

If that fails or shows below 3.10:
- **macOS:** `brew install python@3.12`
- **Windows:** `winget install Python.Python.3.12`
- **Linux:** `sudo apt-get install -y python3.12`

Then install the one library the checks need:

```bash
python3 -m pip install pyyaml
```

Without it, `verify.sh` cannot check that your YAML files parse and will tell you so rather than
quietly skipping.

Windows users: the command is `python`, not `python3`.

---

### 5. Git — version control

Almost certainly already installed. Check:
```bash
git --version
```
If not: `brew install git` / `winget install Git.Git` / `sudo apt-get install -y git`.

---

### Optional, needed later (Step 2, not now)

```bash
# Terraform — creates AWS infrastructure from code
brew install terraform           # or: winget install HashiCorp.Terraform

# AWS CLI — talks to AWS from your terminal
brew install awscli              # or: winget install Amazon.AWSCLI
```

Skip these for now. You do not need an AWS account to complete this guide.

---

## Step B — Get the code

```bash
# Replace with your actual repository URL once it exists
git clone https://github.com/social-remit/social-remit-platform.git
cd social-remit-platform
```

If you were handed a zip instead:
```bash
unzip social-remit-platform.zip
cd social-remit-platform
git init && git add . && git commit -m "Step 1: platform foundation"
```

**One-time step (macOS and Linux):** make the helper scripts executable. Zip archives do not
preserve this permission, so it has to be set once after unzipping.

```bash
chmod +x scripts/*.sh
```

Windows users can skip it — you will run the scripts through Git Bash as `bash scripts/...`.

---

## Step C — Install the contract tools

One command, run from inside the project folder:

```bash
npm install -g @redocly/cli@latest ajv-cli@5 ajv-formats@3
```

**What these are:**
- `redocly` — checks our API definition is valid and warns if a change would break the mobile app.
- `ajv` — checks our event definitions are valid.

If you get a permissions error on macOS or Linux, do **not** use `sudo`. Use this instead:
```bash
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
echo 'export PATH=~/.npm-global/bin:$PATH' >> ~/.zshrc   # or ~/.bashrc
source ~/.zshrc
npm install -g @redocly/cli@latest ajv-cli@5 ajv-formats@3
```

**Check it worked:**
```bash
redocly --version
ajv help
```

---

## Step D — Verify everything

Run the project's own health check:

```bash
bash scripts/verify.sh
```

This form works on macOS, Linux and Windows (through Git Bash) whether or not you ran the `chmod`
above. If you did run it, `./scripts/verify.sh` works too.

You should see a series of green checks ending in `ALL CHECKS PASSED`.

**What it just did:**
1. Confirmed the API definition is valid YAML and valid OpenAPI.
2. Confirmed the event definitions are valid.
3. Confirmed no event can leak a passcode, OTP or access token — it scans for forbidden field
   names and fails the build if it finds one.
4. Confirmed every error code in the catalogue exists in the C# code, and vice versa. If these
   drifted apart, customers would see the wrong error message.

If a check fails, the output names the exact file and line. Fix it and run again.

---

## Step E — Start the local database

```bash
bash scripts/dev-up.sh
```

This checks the ports are free *before* starting anything, then brings up three containers and
waits for them to report healthy. (`docker compose up -d` works too, but gives you a raw daemon
error if a port is taken.)

The three containers:

| Container | What it is | Port on your machine |
|---|---|---|
| `socialremit-postgres` | The database each service will own a slice of | **5433** |
| `socialremit-redis` | Short-lived state (rate limit counters, caches) | **6380** |
| `socialremit-localstack` | A fake AWS on your laptop — SQS, EventBridge, S3, Secrets Manager | 4566 |

Note the ports: PostgreSQL is on **5433**, not the usual 5432, and Redis on **6380**, not 6379.
Those defaults exist because a PostgreSQL already installed on your machine is the most common
setup collision there is, and Docker cannot bind a port something else is holding.

Inside Docker the containers still use their standard ports. The numbers above only matter when
you connect from your own machine. To change them, copy `.env.example` to `.env` and edit.

LocalStack means you can develop and test queues and events without an AWS account and without
spending anything.

The script prints the status of each container when it finishes. All three should say `healthy`.
First run downloads about 400 MB of images and can take several minutes — that is normal and
happens once.

You can check again at any time with:
```bash
docker compose ps
```

---

## Step F — Create the database tables

```bash
bash scripts/dev-db.sh
```

This applies `db/platform/001_building_blocks.sql` and creates three tables that **every** service
will have its own copy of:

- **`outbox_events`** — events waiting to be published.
- **`inbox_messages`** — record of events already handled, so a repeat delivery is ignored.
- **`idempotency_records`** — record of requests already processed, so a retry does not do the work twice.

Why these matter is explained in `docs/HOW_IT_WORKS.md`. Read that next — it is the most important
document in the repo for understanding *why* the code looks the way it does.

**Check it worked:**
```bash
docker exec -it socialremit-postgres psql -U socialremit -d socialremit_dev -c '\dt identity_access.*'
```

You should see `outbox_events`, `inbox_messages` and `idempotency_records`.

Note the `identity_access.` prefix. A bare `\dt` reports "Did not find any relations" — that is
correct, not a failure. `\dt` looks only at the `public` schema, and nothing lives there. Each
service owns its own schema, which is how they stay isolated. In production each becomes a
separate database entirely.

See all seven at once:
```bash
docker exec -it socialremit-postgres psql -U socialremit -d socialremit_dev \
  -c "SELECT table_schema, count(*) AS tables
      FROM information_schema.tables
      WHERE table_schema NOT IN ('pg_catalog','information_schema')
      GROUP BY 1 ORDER BY 1;"
```
Seven schemas, three tables each.

That form runs `psql` *inside* the container, so it works regardless of which host port you chose
and needs nothing installed on your Mac. If you want your own `psql` client on the host, macOS
does not ship one — install it first:
```bash
brew install libpq && brew link --force libpq
psql -h localhost -p 5433 -U socialremit -d socialremit_dev
```
This is optional; the `docker exec` form does the same job. Type `\q` and Enter to exit an
interactive prompt.

---

## Step G — Look at the API

```bash
bash scripts/api-docs.sh
```

This builds a browsable HTML page and opens it. You will see every endpoint the mobile app is
allowed to call, with request and response shapes. This is the contract — the promise the backend
makes to the app.

Under the hood it runs:
```bash
redocly build-docs contracts/openapi/mobile-bff.v1.yaml -o build/api-docs.html
```

If you find `redocly preview-docs` in an older note, it no longer exists — it was removed in
Redocly CLI v2. `build-docs` is the replacement.

---

## You are done

You now have:
- A working development machine.
- A local database with the shared plumbing tables.
- A way to check your changes before you push them.

**Read next, in this order:**
1. `docs/HOW_IT_WORKS.md` — why outbox, inbox and idempotency exist. Plain language, no jargon.
2. `docs/GLOSSARY.md` — every term used in this repo, defined.
3. `CONTRIBUTING.md` — how to make a change without breaking the mobile app.
4. `README.md` — the full 14-step build plan and where Step 1 sits in it.

---

## Common problems

**`dotnet: command not found` right after installing**
Close the terminal and open a new one. Installers modify PATH; open terminals do not reload it.

**`Cannot connect to the Docker daemon`**
Docker Desktop is not running. Start it and wait for the whale icon to stop animating.

**`ports are not available ... address already in use`**
Something on your machine already holds that port. Find out what:

```bash
lsof -nP -iTCP:5433 -sTCP:LISTEN     # macOS / Linux — change the number to the reported port
netstat -ano | findstr :5433         # Windows
```

Then either stop it, or pick a different port. Do not edit `docker-compose.yml` — copy the example
env file and change the number there:

```bash
cp .env.example .env
# edit SR_POSTGRES_PORT / SR_REDIS_PORT / SR_LOCALSTACK_PORT
docker compose down
docker compose up -d
```

Common holders of these ports on a Mac: Postgres.app and `brew services` PostgreSQL on 5432,
a Homebrew Redis on 6379. Stop a Homebrew service with `brew services stop postgresql@16`.

**A previous `docker compose up` failed halfway**
Some containers started and others did not. Clear the partial state before retrying:

```bash
docker compose down
docker compose up -d
docker compose ps
```

**`redocly: command not found` after npm install -g**
npm's global folder is not on your PATH. Use the `~/.npm-global` fix in Step C.

**`verify.sh: Permission denied`**
```bash
chmod +x scripts/*.sh
```
Or just prefix it: `bash scripts/verify.sh`.

**`OpenAPI lint reported problems`**
The full linter output is printed underneath, with file and line numbers. The most common cause is
an unquoted comma inside a YAML flow mapping — `{ description: A, B }` silently becomes two
properties. Quote the value or use a block mapping.

**`dotnet build` fails with package version errors**
Expected at Step 1. `Directory.Packages.props` contains indicative .NET 10 package versions that
were never resolved against a real registry. Run `dotnet restore` and correct the versions it
rejects. There is also no `.sln` and no service projects yet — those arrive in Step 3.

**`psql: Did not find any relations`**
Not a failure. Tables live in per-service schemas, not `public`. Use `\dt identity_access.*`, or
`\dnS` to list every schema.

**`zsh: command not found: psql`**
macOS does not ship a PostgreSQL client. You do not need one — use the `docker exec` form. If you
want it anyway: `brew install libpq && brew link --force libpq`.

**`redocly preview-docs` just prints the command list**
That command was removed in Redocly CLI v2. Use `bash scripts/api-docs.sh` instead.

**Everything is broken and I want to start over**
```bash
docker compose down -v    # -v deletes the database volume too
docker compose up -d
bash scripts/dev-db.sh
```
