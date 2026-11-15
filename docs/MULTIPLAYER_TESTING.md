# Multiplayer: Launching and Testing (Slices 003–004)

## Persistent realm (Slice 004): one-time setup

```bash
pip install -r tools/keeper/requirements.txt
tools/db/dev_db.sh init
```

`init` does the following:
1. Creates a PostgreSQL cluster in `.dev/pg`, listening on 127.0.0.1:55432.
2. Generates `.dev/env` with random passwords and `KEEPER_SECRET` (it is
   gitignored).
3. Creates the `mmo` database.
4. Applies the migrations.

To use Docker instead, see `docker-compose.yml`.

## Play the persistent realm (three terminals)

```bash
tools/db/dev_db.sh start                         # PostgreSQL (if not running)
tools/keeper/run_keeper.sh                       # Keeper: persistence + accounts (loopback only)
tools/net/run_server.sh --persistent             # dedicated server; Ctrl+C = graceful save + shutdown
tools/net/run_client.sh Alice                    # each player: connect, then log in / create a character
```

In the client, **F9** opens the realm panel:
- connect, then the login window appears;
- the character window lists, creates and enters characters;
- **Leave world** goes back to the character window, and **Log out** is on
  the character window.

The temporary-session mode from Slice 003 is still available:
`tools/net/run_server.sh` without `--persistent`.

## Slice 005 combat tests

| Suite | Command | Checks |
|---|---|---|
| Combat rules (offline authority, deterministic) | `godot --headless --path game --script res://tests/combat_tests.gd` | 60 |
| Combat over the network with persistence: co-op wolf kill, single death, single loot, skills persisted across a restart, abuse | Part of `tests/persist/run.sh` (t10–t12) | see PROJECT_STATE |
| GUI combat walkthrough: armory, Stormcaller, wolf, remains, bow vs. skeleton, defeat and respawn | `xvfb-run godot --rendering-driver opengl3 --path game -- --scenario=combat --shot_dir=/tmp/c --nohelp` | 16 |

## Slice 004 automated acceptance

| Suite | Command | Checks |
|---|---|---|
| Keeper against PostgreSQL | `tests/keeper/run.sh` | 41 |
| Persistence with real processes: Keeper and the server restarted and killed, PostgreSQL stopped mid-test | `GODOT=... tests/persist/run.sh` | 113 |
| Definition of Done with two GUI clients: register, create, play, log out, restart server and Keeper, log in, verify | `GODOT=... tests/persist/dod_gui.sh` (needs Xvfb) | 38 |

All three use disposable databases (`mmo_test` and `mmo_dod`) in the dev
cluster and never touch `mmo`.

All commands run from the repository root. `godot` means a Godot **4.3+**
binary; set `GODOT=/path/to/godot` for the helper scripts.

## Play: one server and two clients on one computer

```bash
tools/net/run_local_mp.sh
```

The script starts a headless dedicated server on 127.0.0.1:24680, then two
client windows side by side named **Alice** and **Bob**. Ctrl+C stops
everything.

Or start each process yourself:

```bash
# 1. dedicated server (headless, localhost only)
godot --headless --path game res://scenes/server.tscn -- --port=24680

# 2. client 1 and client 2 (separate terminals)
godot --path game -- --connect=127.0.0.1:24680 --name=Alice
godot --path game -- --connect=127.0.0.1:24680 --name=Bob
```

You can also start a plain client with `godot --path game`, then press **F9**
to open the **Realm Connection** window. Enter the server, port and name,
then press **Enter the realm**.

### LAN (two computers)

1. On the host, start the server with `--bind=0.0.0.0` (or the host's LAN IP)
   and allow UDP port 24680 in its firewall:
   ```bash
   tools/net/run_server.sh --bind=0.0.0.0
   ```
2. On the other computer:
   ```bash
   tools/net/run_client.sh Bob 192.168.x.y
   ```

This is an **unauthenticated development server**. Use it only on a trusted
LAN; never port-forward it to the internet.

### Useful server options

```
--port=24680 --bind=127.0.0.1 --tick=30 --state_rate=12 --linger=8 --max_clients=16 --stats=30
--lag=120 --jitter=40 --loss=0.05      # artificial network conditions on everything the server sends
```

Clients accept the same `--lag`, `--jitter` and `--loss` (applied to what they
send), plus `--no_predict` to turn off local movement prediction.

## Automated tests

| Suite | Command | What it covers |
|---|---|---|
| Rules and invariants (single-player authority) | `godot --headless --path game --script res://tests/run_tests.gd` | 79 checks; the Slice 002 item and interaction contract |
| **Multiplayer** | `godot --headless --path game --script res://tests/mp_tests.gd` | 93 checks: a real ENet server and two real clients in one process, directive tests 01–10 plus protocol garbage |
| Single-player UI acceptance | `xvfb-run godot --rendering-driver opengl3 --path game -- --scenario=acceptance --shot_dir=/tmp/shots` | 43 checks through synthetic mouse/keyboard (Slice 002 regression) |
| **Three-process multiplayer UI run** | see below | Separate server, Alice and Bob processes; UI-driven door, pickup, equip, observed by the other client |

Run `godot --headless --editor --quit --path game` once after adding scripts
with a `class_name`.

### Three-process run (what produced `docs/images/slice003/`)

```bash
G=godot
cd game
$G --headless --path . res://scenes/server.tscn -- --port=24690 --lag=60 --jitter=20 --loss=0.05 &
xvfb-run -a $G --rendering-driver opengl3 --path . -- --connect=127.0.0.1:24690 --name=Bob   --lag=60 --jitter=20 --loss=0.05 --scenario=mp_bob   --shot_dir=/tmp/mp/bob   --nohelp &
sleep 3
xvfb-run -a $G --rendering-driver opengl3 --path . -- --connect=127.0.0.1:24690 --name=Alice --lag=60 --jitter=20 --loss=0.05 --scenario=mp_alice --shot_dir=/tmp/mp/alice --nohelp
```

Alice:
1. opens the cottage door by double-clicking it;
2. double-clicks the sword to pick it up;
3. drags it onto the Main Hand slot;
4. walks over to Bob.

Bob's process checks that it sees each of those changes, including the weapon
drawn on Alice. Both processes exit with code 0 when every check passes.

## Manual two-player checklist

With `tools/net/run_local_mp.sh`:

1. **Both players in the world.** Each window shows two characters with name
   labels. Walking in one window is seen in the other, with matching facing.
2. **Shared door.**
   - Alice double-clicks the door and it opens in both windows.
   - Bob walks to it and double-clicks, and it closes for both.
   - Walking into the closed door is blocked in both windows.
3. **Shared chest.**
   - Both go inside and double-click the chest; both chest windows show
     3 items.
   - Alice drags the apples into her backpack, and Bob's chest window drops
     to 2/8 immediately.
4. **Simultaneous pickup.** Both double-click the sword at the same moment.
   One gets it; the other sees "That item is no longer there."
5. **Equipment.** Alice equips the sword and Bob sees it in her hand.
   Alice unequips it and it disappears.
6. **Disconnect.**
   - Close Alice's window. Bob's journal says "Alice left the world", and
     anything Alice carried lies where she stood.
   - Kill Alice's process instead, and she shows "(link lost)" for 8 s, then
     goes away.
7. **Server shutdown.** Stop the server. Both clients return to the offline
   world and the connection panel shows the reason.
