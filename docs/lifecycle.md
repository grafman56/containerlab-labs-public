# Lab lifecycle

One manifest, one driver, one gate.

## Why this exists

The lab registry used to live in three places at once: nine topology files,
four copies of `labctl`, and a markdown table. Three of the four `labctl`
scripts were byte-identical. Five labs had no entry point at all. The table
listed six labs and five management subnets, and the topology sources had nine
of each.

`labs.toml` is now the only place a lab is described. `./labctl` reads it.
`./validate-repository.sh` reads it. A table of labs can be
generated from it.

## The manifest

One `[labs.<name>]` table per lab. The name is the Containerlab name, so the
container prefix is always `clab-<name>-`.

| Key | Required | Meaning |
|---|---|---|
| `dir` | yes | Directory that holds the lab. |
| `topology` | yes | Topology file inside that directory. |
| `summary` | no | One line, used by `./labctl list`. |
| `driver` | no | `containerlab` (default) or `netlab`. |
| `mgmt_subnet` | yes | Management CIDR. Must match the topology and must be unique. |
| `images` | no | Images the lab pulls before deploy. Each must be pinned. |
| `external_images` | no | Images that must already exist locally. The driver never pulls them. |
| `docker_builds` | no | `{ image, context }` pairs built before deploy. |
| `runtime_owner` | no | `uid:gid` applied to the runtime directories. |
| `verify` | no | Verification scripts, relative to the lab directory, run in order. |
| `[labs.<name>.hooks]` | no | Scripts run around deploy and destroy. See below. |
| `automation_only` | no | Reason the lab must run through the automation templates. |
| `automation_template` | no | Template name printed when the driver refuses. |
| `min_free_memory_mb` | no | Memory the lab needs. `doctor` warns when the host has less. |

### Hooks

Four phases, each a list of commands. The first element is a script path
relative to the lab directory. The rest are arguments.

```toml
[labs.wireless-radius-8021x.hooks]
pre_deploy = [["lifecycle.sh", "pre-deploy"]]
post_deploy = [["lifecycle.sh", "post-deploy"]]
pre_destroy = [["lifecycle.sh", "pre-destroy"]]
post_destroy = [["lifecycle.sh", "post-destroy"]]
```

A deploy hook that fails stops the deploy. A destroy hook that fails is
reported and the teardown continues, because a half-destroyed lab is worse
than a destroyed one with a warning.

Hooks are script paths, not shell strings. The script must exist in the
repository, so `./labctl check` can prove that it does. The path is relative to
the lab directory, so a shared script is reached with `..`.

A lab can run host-side helpers around deploy and destroy. For example, a sidecar
that needs a socket directory must create it before the deploy, and must start
after the node is up:

```toml
[labs.ibgp-rr.hooks]
pre_deploy = [["scripts/extra.sh", "prepare"]]
post_deploy = [["scripts/extra.sh", "start"]]
pre_destroy = [["scripts/extra.sh", "stop"]]
```

That ordering matters. `prepare` creates `runtime/<node>` with owner 100:101,
the same directory the driver creates from the topology binds, so the two steps
agree instead of racing. `start` needs `clab-<lab>-<node>` to exist. Without
these hooks a deployed lab looks healthy while the Grafana dashboard stays
empty, and a destroyed lab leaves exporters holding ports 9342-9369.

### Runtime directories

Seven topologies bind `runtime/<node>` into a container, usually at
`/var/run/frr`. The driver reads those bind sources from the topology and
creates one directory per binding, so the list of node names is never written
down twice.

When `runtime_owner` is set, the driver applies that owner. The FRR daemons run
as `frr:frr` (100:101) inside the image and die on a pid file they cannot
write. This replaces the hand-maintained `mkdir` and `chown` sequence that
used to live inside one script.

## Commands

```sh
./labctl list                    # every lab, with node count from the topology
./labctl list --markdown         # a markdown table of the labs
./labctl check                   # manifest against topology sources
./labctl check --with-validator  # the whole gate
./labctl doctor                  # host preflight
./labctl up evpn-vxlan --dry-run # print every command, change nothing
./labctl up evpn-vxlan
./labctl verify evpn-vxlan
./labctl status evpn-vxlan
./labctl down evpn-vxlan
```

Each lab directory keeps a `labctl` shim, so `cd evpn-vxlan && ./labctl up`
still works.

## What `up` does, in order

1. Refuse the lab if it is `automation_only` or netlab-managed.
2. Run `doctor` checks on docker, containerlab, sudo, memory and disk.
3. Run the `pre_deploy` hooks.
4. Create the runtime directories from the topology binds, and set their owner.
5. Build the local images, then pull the rest.
6. Run `containerlab deploy -t <topology>` from the lab directory.
7. Run the `post_deploy` hooks.

`down` runs the `pre_destroy` hooks, then
`containerlab destroy -t <topology> --cleanup`, then the `post_destroy` hooks.

## Safety rules the driver enforces

- Every changing command names one lab. There is no `--all`.
- The driver never passes `--all` to Containerlab. A test asserts this.
- A lab with `automation_only` is refused, with the template name printed.
- A netlab lab is refused, with a pointer to its README.
- An unknown lab is refused, with the list of known labs.
- `down` prints the lab, the topology, and the container prefix before it runs.
- One lab's command never touches another lab's containers.

## Adding a lab

1. Create the directory and the topology. Pin every image.
2. Pick a management CIDR that no other lab and no Docker network uses.
3. Add a `[labs.<name>]` entry to `labs.toml`.
4. Run `./labctl check`. It fails on a name mismatch, a subnet mismatch, an
   unpinned image, an image the topology uses but the manifest does not
   declare, and a missing verify or hook script.
5. Run `./labctl up <name> --dry-run` and read the commands.
6. Run `./labctl up <name>`, then `./labctl verify <name>`.

## Why TOML and a separate reader

The driver uses only the Python standard library, so it runs on a lab host
with no packages installed. Python 3.11 or newer is required for `tomllib`.

Topology facts are read by a small indentation reader, not a YAML parser. It
reads the name, the management subnet, node kinds, node images and bind
sources, and nothing else. `validate-repository.sh` still parses every topology
with PyYAML, so a disagreement between the two shows up as a failing check
rather than as a wrong assumption.

## Porting this to another repository

Three files carry the pattern and are not specific to this lab set:

- `labctl` - the driver. It reads the repository layout from `labs.toml`.
- `labs.toml` - the manifest. Replace the entries, keep the keys.
- `tests/test_labctl.py` - the safety and parsing tests.

`validate-repository.sh` has two parts. The manifest check calls `./labctl
check` and needs no change. The topology checks and the declared-inventory
checks are specific to the labs in this repository; keep or replace them.

A lab set that does not use Containerlab can still use the manifest. Set
`driver` and the driver refuses the lifecycle verbs with a readable message,
which is what happens to `enterprise-fabric` here.
