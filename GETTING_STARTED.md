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
docker compose up -d
```

This starts three containers:

| Container | What it is | Port |
|---|---|---|
| `socialremit-postgres` | The database each service will own a slice of | 5432 |
| `socialremit-redis` | Short-lived state (rate limit counters, caches) | 6379 |
| `socialremit-localstack` | A fake AWS on your laptop — SQS, EventBridge, S3, Secrets Manager | 4566 |

LocalStack means you can develop and test queues and events without an AWS account and without
spending anything.

**Check they started:**
```bash
docker compose ps
```
All three should say `running` or `healthy`. Give it 20–30 seconds on first run — it downloads
images.

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
docker exec -it socialremit-postgres psql -U socialremit -d socialremit_dev -c '\dt'
```
You should see the three tables listed. Type `\q` and Enter to exit if it drops you into a prompt.

---

## Step G — Look at the API

```bash
redocly preview-docs contracts/openapi/mobile-bff.v1.yaml
```

Open http://localhost:8080 in your browser. You will see every endpoint the mobile app is allowed
to call, with request and response shapes. This is the contract — the promise the backend makes to
the app. Press `Ctrl+C` in the terminal to stop it.

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

**`port 5432 is already allocated`**
You have PostgreSQL already running on your machine. Either stop it
(`brew services stop postgresql`) or change the port in `docker-compose.yml` from `5432:5432` to
`5433:5432` and use 5433 in your connection strings.

**`redocly: command not found` after npm install -g**
npm's global folder is not on your PATH. Use the `~/.npm-global` fix in Step C.

**`verify.sh: Permission denied`**
```bash
chmod +x scripts/*.sh
```

**`dotnet build` fails with package version errors**
Expected at Step 1. `Directory.Packages.props` contains indicative .NET 10 package versions that
were never resolved against a real registry. Run `dotnet restore` and correct the versions it
rejects. There is also no `.sln` and no service projects yet — those arrive in Step 3.

**Everything is broken and I want to start over**
```bash
docker compose down -v    # -v deletes the database volume too
docker compose up -d
bash scripts/dev-db.sh
```
