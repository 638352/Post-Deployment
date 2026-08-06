# Server & processor map (OMS outbound/inbound)

> Sensitive infrastructure detail. Keep this repo private.
> Source: environment cheat sheet; confirm against the "Outbound Deployment
> Steps" runbook and Server Notes before wiring a per-server deploy script.

**Scope (per the leadership brief):** OMS .NET executables, PowerBuilder
binaries, and their configurations, including every Citrix server that receives
a manual deployment copy. MERA and gateway cloud services are **excluded** —
they already have standard deployment processes. Database objects are planned
as a fast follow (out of scope for the current two-week window).

## Servers by tier

### Inbound processing
| Tier | Server | Role |
|------|--------|------|
| DEV  | VESDEVAPPS01     | both inbound and outbound |
| UAT  | VESEMSINGRESUAT  | inbound |
| PROD | VESEMSINGRESS01  | real-time Inbound Request Processor |
| PROD | VESEMSINGRESS02  | Handler |

### Outbound processing
| Tier | Server | Processors running there |
|------|--------|--------------------------|
| DEV  | VESDEVAPPS01    | both inbound and outbound |
| UAT  | VESMSEGRESSUAT  | Ack, DBQ, XML (all on one box) |
| PROD | VESEMSEGRESS01  | XML / Outbound Events |
| PROD | VESEMSEGRESS02  | Ack, DBQ, XML / Outbound Events |
| PROD | VESEMSEGRESS03  | XML / Outbound Events, DBQ |

The PROD split (VEMS-5346) is why deploy/verify is server-aware: a given
processor only exists on the servers listed above, so each per-server wrapper
targets only the processors on that box.

### Databases (out of scope — fast follow)
Database objects (stored procedures, triggers, views) are excluded from the
current effort per the brief's Scope; they fit the same capture-and-verify
pattern and are a planned fast follow. Kept here for reference only.

| Tier | Server | Database |
|------|--------|----------|
| DEV  | VESSQLDEV101 | OMS2 |
| UAT  | VESSQLUAT101 | OMS2 |
| PROD | VESSQLOMS101 | OMS2 |

### Citrix servers (in scope — details pending)

Every Citrix server that receives a manual deployment copy is in scope per the
brief. Server names and processor paths have not yet been documented here.
Operations must supply them before `inventoryComplete` can be set to `true` in
`targets.json`. Add one `targets.json` entry per server/processor copy and list
each server in `requiredServers`.

### Java / cloud-service hosts (out of scope — later work)
The gateway services and MERA (VESOMSVEMS01/02, VESMERA01) are excluded per
the brief's Scope: they already have standard deployment processes, and tying
them to the same Git release discipline is planned as later work. They are not
part of the required manual-copy inventory in targets.json.

## How the outbound processors actually run

There is ONE executable, `VES.OutboundDBQProcessor.exe`, deployed into a
processor folder and launched by a `.bat` file with a mode argument. The
mode arg (not the exe name) selects the processor behavior:

| Processor | Mode arg | Notes |
|-----------|----------|-------|
| Ack | `RTP`    | |
| DBQ | `RTPDP`  | |
| XML / Outbound Request | `RTP` | same arg as Ack; the folder/batch distinguishes it |

Because the same exe name runs 2-3 times per server, you cannot identify or stop
an instance by process name alone -- match on its working directory /
command-line arg.

**A folder is not always one processor.** XML and DBQ share a single directory on
UAT, on VESEMSEGRESS02 and on VESEMSEGRESS03; only the mode argument tells the
two instances apart. Where that happens the folder is one *deployment unit*
carrying two processors, with consequences the scripts inherit:

- Stopping the tree stops BOTH instances (`Stop-VesProcessorTarget` matches on
  executable path under TargetRoot and takes no mode argument), so there is no
  way to deploy one of them in isolation. The runbook does the same thing.
- Both tasks must be listed on the wrapper, or the mirror runs while the
  unlisted processor still holds files open and it is never restarted.
- Both write to the same log directory, so `-FreshLogDir` proves only that
  *something* in the tree is alive. Per-processor liveness comes from the task
  last-run result and the `-ProcessArgumentPattern` match, not from log freshness.

### UAT VESMSEGRESSUAT
| Processor | Batch | Working dir | Launch |
|-----------|-------|-------------|--------|
| Ack | `C:\VLER_TEST_ACK\Batch\VLER_EM_Realtime_Acknowledgement_Processor.bat` | `C:\VLER_TEST_ACK\Processors\VES.OutboundProcessor` | `start VES.OutboundDBQProcessor.exe RTP` |
| DBQ | `C:\VLER_TEST_OUTBOUND\Batch\VLER_EM_Realtime_DBQ_Processor.bat` | `C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` | `start VES.OutboundDBQProcessor.exe RTPDP` |
| XML | `C:\VLER_TEST_OUTBOUND\Batch\VLER_EM_Realtime_Outbound_Request_Processor.bat` | `C:\VLER_TEST_OUTBOUND\Processors\VES.OutboundProcessor` | `start VES.OutboundDBQProcessor.exe RTP` |

### DEV VESDEVAPPS01
| Processor | Batch | Launch |
|-----------|-------|--------|
| Ack | `E:\EMSEGRESSACK\VLER_Test\Batch\VLER_EM_Realtime_Ack_ORP.bat` | `start E:\EMSEGRESSACK\VLER_Test\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe RTP` |
| DBQ | `E:\EMSEGRESSDBQ\VLER_Test\Batch\VLER_EM_Realtime_DBQ_Processor.bat` | `start E:\EMSEGRESSDBQ\VLER_Test\Processors\VES.OutboundProcessor\VES.OutboundDBQProcessor.exe RTPDP` |
| XML | `E:\EMSEGRESS\VLER_Test\Batch\VLER_EM_Realtime_Outbound_Request_Processor.bat` | `cd C:\VLER_Test\Processors\VES.OutboundProcessor` then `start VES.OutboundDBQProcessor.exe RTP` |

### PROD deployment units

Source: **4.7 Deployment Instructions** (rollout section). One row per unit that
receives a deployment copy; the wrapper in `processors/` pins these values and
refuses to run on any other server.

| Server | Unit | Target dir | Stop/start | Log dir | Config |
|--------|------|-----------|------------|---------|--------|
| VESEMSINGRESS01 | Realtime inbound | `C:\VLER\Processors\VES.RealtimeInboundEventService` | **service** `VES.RealtimeInboundEventService` | `C:\VLER\Logs\VES.InboundProcessor` | preserved |
| VESEMSINGRESS02 | Inbound handler | `C:\VLER\Processors\VES.InboundProcessor` | task `VLER EM Inbound _ Request _ Handler` | `C:\VLER\Logs\VES.InboundProcessor` | preserved |
| VESEMSEGRESS01 | XML / Outbound | `C:\VLER\Processors\VES.OutboundProcessor` | task `VLER_EM_Real_Time_Outbound_Processor` | `E:\VLER\Logs\VES.OutboundProcessor` | **replaced** |
| VESEMSEGRESS02 | Ack | `C:\VLER\Processors\VES.OutboundProcessor` | task `VLER_EM_Real_Time_Acknowledgement_Processor` | `E:\VLER\Logs\VES.OutboundProcessor` | preserved |
| VESEMSEGRESS02 | XML + DBQ | `C:\VLER_OUTBOUND_AND_DBQ\Processors\VES.OutboundProcessor` | tasks `VLER_EM_Real_Time_DBQ_Processor` **and** `VLER_EM_Real_Time_Outbound_Processor` | `E:\VLER_OUTBOUND_AND_DBQ\Logs\VES.OutboundProcessor` | preserved |
| VESEMSEGRESS03 | XML + DBQ | `C:\VLER\Processors\VES.OutboundProcessor` | tasks `VLER_EM_Real_Time_DBQ_Processor` **and** `VLER_EM_Real_Time_Outbound_Processor` | `E:\VLER\Logs\VES.OutboundProcessor` | preserved |

Four things in that table are load-bearing:

- **PROD task names use `Real_Time`, UAT uses `Realtime`.** They are different
  strings. Do not copy a UAT wrapper's task name into a PROD one.
- **VESEMSEGRESS01 and 03 share a TargetRoot path on different boxes.** Each
  wrapper asserts its own hostname (`Test-VesRunbookValues -ExpectedServer`);
  that assert is the only thing distinguishing them before the mirror runs.
- **VESEMSEGRESS01 is the one unit that replaces its config** ("delete all files
  INCLUDING the exe.config file", plus a pre-edited replacement). Its wrapper
  leaves `PreserveFiles` empty, so the gate requires the config in the staged
  package. Every other unit preserves the server's own config with `/XF`.
- **VESEMSINGRESS02 also runs five SQL scripts before its file copy.** Database
  objects are out of scope per the brief, so no script here deploys or verifies
  them; the wrapper takes a separate `-ConfirmedSqlRolloutComplete`
  acknowledgement rather than pretending the step does not exist.

The 4.7 document has two known errors, corrected above: the VESEMSEGRESS01
rollout section is headed "Vesemsingress01", and both inbound **rollback**
sections name `VES.OutboundProcessor` where the rollout names the inbound tree.
Following the rollback text literally would clear the wrong directory.

## What this means for the scripts

- **Stop for deploy** is implemented as more than stop-service/disable-task: a running
  instance is a `VES.OutboundDBQProcessor.exe` process holding its folder's files
  open, so `Deploy-Processor.ps1` stops only the instance whose executable path
  is under the target root; the PID and command line/mode argument are audited.
  Where two processors share that root, both are stopped -- see above.
- **Health "is running"** uses `-ProcessPathRoot` plus optional
  `-ProcessArgumentPattern`, so the same executable name in another processor
  folder cannot satisfy the check. For a shared folder the mode pattern is what
  does the work: `\bRTPDP\b` for DBQ alone, `\bRTP(DP)?\b` to cover both.
- **TargetRoot** is the `...\Processors\VES.OutboundProcessor` folder for that
  unit, and it differs per server and tier (C:\ on UAT, E:\ on DEV, and two
  different C:\ roots on VESEMSEGRESS02), so each wrapper hard-codes its own
  paths and asserts its own hostname.
- **Multi-value parameters cross process boundaries joined, not repeated.** Every
  stage runs as a `powershell.exe -File` child and -File cannot bind an array:
  repeating a named argument is `ParameterAlreadyBound` and `-X a,b` binds as one
  string. `ConvertTo-VesList`/`Expand-VesList` own that transport. This is why a
  two-task unit works at all.
- **Inventory is fail closed**: add one confirmed `targets.json` entry per
  server/processor deployment copy. The drift runner will not run while the
  required-server/Citrix inventory is incomplete.
