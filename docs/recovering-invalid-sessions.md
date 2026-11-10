# Recovering an invalid session

The label stage (`assign`) names each session from three DICOM tags: the
project, the subject and the session ID. When a tag is empty, the stage cannot
name the session. It moves the session to `/data/assigned/__invalid__/` on the
edge and does not upload it. This page tells you how to move the session back
after a person finds the missing value.

The stage behaviour (the log line, the alert, what happens to the Orthanc,
grouped and backup copies) is in
[components/accessionflow.md](components/accessionflow.md#recovering-an-invalid-session).

## What you see

- The alert `InvalidSessionAssigned` fires. It counts log lines, not sessions,
  and it clears after 10 minutes. A clear alert does not mean that the session
  was recovered.
- The folder name shows the missing ID:
  `<project>.<subject>.INVALID_MISSING_<FIELD>_<suffix>`, for example
  `test_project.MRN1.INVALID_MISSING_ACCESSIONNUMBER_ognMmX8R`.
- Nothing removes the folder. Do not delete it to clear the alert. When the
  facility backup is off, it can be the only copy of the study.

## Who does what

| Who | Does | Needs |
|---|---|---|
| The operator | Gets the alert. Runs `list` and `show`. Runs `requeue` with the value. | One of the methods below |
| A person with the hospital's records (a clinician or a data manager) | Finds the missing value in the RIS or the PACS, from the details that `show` prints | No access to the edge |

Nothing finds the value for you: the DICOM tag was empty. The tool never
guesses it.

## The procedure

1. Run `list`. It shows each folder in `__invalid__/` and the missing ID.
2. Run `show <folder>`. It prints the study details: PatientID, the study date
   and time, the description, the modality, the AccessionNumber and the
   StudyInstanceUID. These are patient data. Keep them on the terminal.
3. Give the details to the person with the hospital's records. That person
   finds the missing value.
4. Make sure that the XNAT project has no session with the new label.
5. Run `requeue <folder> --session <value>`. Give `--project`, `--subject` or
   `--session` for each ID that the folder misses, and only for those.
6. Look for the session in the log of `mgmt-upload-<edge>`, then in XNAT.

Use one of the methods below for steps 1, 2 and 5. All of them run the same
tool, except the manual fallback.

## Choose a method

| Method | Where you run it | You need | sudo |
|---|---|---|---|
| [1. The edge command](#method-1-the-edge-command) | The edge node (the edge VM) | sudo on the edge node | Yes |
| [2. The edge command, sudo for this command only](#method-2-the-edge-command-with-sudo-for-this-command-only) | The edge node | A sudo rule that an admin adds once | Only for this command |
| [3. kubectl](#method-3-kubectl) | The management node, or a machine with a kubeconfig for the edge | kubectl and permission to exec into the label pod | No |
| [4. The repository script](#method-4-the-repository-script) | A clone of this repository | The same as method 3 | No |
| [5. By hand](#method-5-by-hand-the-fallback) | The edge node | sudo on the edge node | Yes |

On tier-2 the edge VM is a k0s worker. kubectl for the edge cluster is on the
management node, not on the edge VM. On the edge VM, use method 1 or 2.

## Method 1: the edge command

Run these commands on the edge node:

```bash
sudo ais-requeue list
sudo ais-requeue show <folder>
sudo ais-requeue requeue <folder> --session <value>
```

You need no kubectl and no copy of this repository. The command needs root,
because k0s's container runtime accepts only root.

If the edge release is not in the namespace `xnat-ingest`, give the namespace
first:

```bash
sudo ais-requeue --namespace <namespace> list
```

### Install the edge command

`scripts/files/edge-join.sh` installs `/usr/local/bin/ais-requeue` when an edge
joins. Both join paths deliver it: `join: ssh` and `join: bundle`.

An edge that joined before the command existed does not have it. Install it
once, from a clone of this repository on the management node:

```bash
scp scripts/files/ais-requeue <edge-node>:/tmp/
ssh <edge-node> sudo install -o root -g root -m 0755 /tmp/ais-requeue /usr/local/bin/ais-requeue
```

Do the same to update the command. The tool in the label pod comes from the
chart, so a chart upgrade updates the tool.

## Method 2: the edge command with sudo for this command only

Use this method when an operator must not have full sudo on the edge node. An
admin lets a group run `/usr/local/bin/ais-requeue` as root, and nothing else.

The admin does these steps once, on the edge node:

1. Make the group:

   ```bash
   sudo groupadd ais-requeue
   ```

2. Add the operator to the group. The operator must log in again.

   ```bash
   sudo usermod -aG ais-requeue <user>
   ```

3. Add the sudo rule, and check it:

   ```bash
   echo '%ais-requeue ALL=(root) /usr/local/bin/ais-requeue' | sudo tee /etc/sudoers.d/ais-requeue
   sudo chmod 0440 /etc/sudoers.d/ais-requeue
   sudo visudo -cf /etc/sudoers.d/ais-requeue
   ```

The operator then uses the commands of method 1. sudo asks for the operator's
own password. Add `NOPASSWD:` before the path if the site does not want that.

This rule is safe for this command. The edge command sets the pipeline folder
(`--root`) and the operator name (`--operator`) itself. The first word must be
`list`, `show` or `requeue`. So no option can come before it. The tool refuses
an option that it does not know. So the operator cannot point the tool at
another folder. The audit line always names the real user (from `SUDO_USER`).

## Method 3: kubectl

Use this method where kubectl can reach the edge cluster. On tier-2, that is
the management node, with the kubeconfig of the edge (`kubeconfig-<edge>`). You
need no sudo.

```bash
kubectl --kubeconfig kubeconfig-<edge> -n xnat-ingest exec deploy/<release>-assign -c assign -- \
  python3 /opt/ais-edge/requeue-invalid.py --operator <your-name> list
```

Use `show <folder>` and `requeue <folder> --session <value>` in place of
`list`. Give your name with `--operator`: the audit line records it.

The kubeconfig must allow `get` on pods and deployments, and `create` on
`pods/exec`, in the namespace. That permission lets a user run any command in
any pod of the namespace. Give it only to operators who can see the pipeline
data.

## Method 4: the repository script

From a clone of this repository, `scripts/requeue-invalid.sh` runs method 3
for you. It finds the label pod and records `<user>@<host>` as the operator.

```bash
scripts/requeue-invalid.sh --kubeconfig kubeconfig-<edge> list
scripts/requeue-invalid.sh --kubeconfig kubeconfig-<edge> show <folder>
scripts/requeue-invalid.sh --kubeconfig kubeconfig-<edge> requeue <folder> --session <value>
```

`--namespace <namespace>` selects another namespace.

## Method 5: by hand (the fallback)

Use this method only when the tool cannot run. It does the same move without
the checks of the tool, and it does not take the label stage's lock.

On the edge node, rename the folder to `<project>.<subject>.<session>` and move
it up into `assigned/`. `/data` is the pipeline hostPath, `/data/xnat-ingest`
by default. The commands stop if a folder of that name exists. `mv -nT` never
replaces a folder and never moves into one. The last `test` checks that the
folder really left `__invalid__/`:

```bash
ssh <edge-node>
cd /data/xnat-ingest/assigned
sudo test ! -e <project>.<subject>.<session> \
  && sudo mv -nT __invalid__/<folder> <project>.<subject>.<session> \
  && sudo test ! -e __invalid__/<folder> \
  && sudo ls -d <project>.<subject>.<session>
```

If a check fails, look at both paths and the stage logs before you do anything
else. A session with that name can already wait, or the next stage can already
have taken the moved folder. Never repeat the move blindly.

## What requeue checks

`requeue` refuses, and moves nothing, when:

- a value is not a legal label: use letters, digits, `_` and `-` only;
- you give a value for an ID that is not missing, or you do not give a missing
  one;
- `assigned/<new name>` or `deidentified/<new name>` already exists. If the
  session in `deidentified/` is the same study (more data for it), add
  `--allow-existing`. A folder that waits in `assigned/` is never merged. Wait
  until deidentify takes it, then run the command again;
- a `grouped/` copy of the same study is still there. assign would put that
  copy in `__invalid__/` again. Wait for it to clear, or remove it first.

It moves the folder under the label stage's lock
(`/data/.locks/assigned.lock`), so a label pass cannot run at the same time.
It checks that the folder left `__invalid__/`. It adds one line for each move
to `/data/LOGS/requeue-audit.jsonl`: who, when, the old and the new name, and
the values given.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | The folder moved |
| 2 | Refused, or a wrong command. The message tells why |
| 3 | No such folder in `__invalid__/` |
| 4 | A label pass holds the lock. Try again |

## After the move

The upload takes the three IDs from the folder name. Do not edit the files. No
method changes the DICOM files. The session then goes on as any other
session: deidentify under `deid.engine: ingest`, the s3-uploader, the bucket
and the management uploader.

Look for the session in the log of `mgmt-upload-<edge>`, then in XNAT. When the
data policy is armed, the reclaimers remove the edge and bucket copies after
their proof.

Do not send the study again to correct it. Orthanc keeps the instances that it
already has, and it ignores a copy with the same SOPInstanceUID.

## How the tool reaches the edge

- The label pod runs the accessionflow image. This chart does not change that
  image. It mounts one more file into the container: the ConfigMap
  `<release>-requeue-tool`, made from `charts/edge/files/requeue-invalid.py`,
  read-only at `/opt/ais-edge`. The tool runs with the `python3` of the image.
  It is a directory mount, so a chart upgrade updates the file without a
  restart of the stage.
- The edge command, `scripts/files/ais-requeue`, is a short shell script. It
  finds the label container that runs (`k0s ctr`: the container name `assign`,
  the namespace, and a task in the state RUNNING). It then runs the tool in
  that container. It gives back the exit code of the tool.
- `scripts/requeue-invalid.sh` runs the same tool with kubectl.
