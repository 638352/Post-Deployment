# Server & processor map (OMS outbound/inbound)

> Sensitive infrastructure detail. Keep this repo private.
> Source: environment cheat sheet; confirm against the "Outbound Deployment
> Steps" runbook and Server Notes before wiring a per-server deploy script.

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

### Java / cloud-service hosts (out of scope — later work)
The gateway services and MERA (VESOMSVEMS01/02, VESMERA01) are excluded per
the brief's Scope: they already have standard deployment processes, and tying
them to the same Git release discipline is planned as later work. They are not
part of the required manual-copy inventory in targets.json.

## How the outbound processors actually run

There is ONE executable, `VES.OutboundDBQProcessor.exe`, deployed into a
per-processor folder and launched by a `.bat` file with a mode argument. The
mode arg (not the exe name) selects the processor behavior:

| Processor | Mode arg | Notes |
|-----------|----------|-------|
| Ack | `RTP`    | |
| DBQ | `RTPDP`  | |
| XML / Outbound Request | `RTP` | same arg as Ack; the folder/batch distinguishes it |

Because the same exe name runs 2-3 times per server (once per processor folder),
you cannot identify or stop an instance by process name alone -- match on its
working directory / command-line arg.

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

PROD paths are not captured here yet -- pull them from the Outbound Deployment
Steps runbook per server before writing the PROD wrappers.

## What this means for the scripts

- **Stop for deploy** is implemented as more than stop-service/disable-task: a running
  instance is a `VES.OutboundDBQProcessor.exe` process holding its folder's files
  open, so `Deploy-Processor.ps1` stops only the instance whose executable path
  is under the target root; the PID and command line/mode argument are audited.
- **Health "is running"** uses `-ProcessPathRoot` plus optional
  `-ProcessArgumentPattern`, so the same executable name in another processor
  folder cannot satisfy the check.
- **Per-processor TargetRoot** is the `...\Processors\VES.OutboundProcessor`
  folder for that processor, and it differs per server and tier (C:\ on UAT,
  E:\ on DEV), so each wrapper hard-codes its own paths.
- **Inventory is fail closed**: add one confirmed `targets.json` entry per
  server/processor deployment copy. The drift runner will not run while the
  required-server/Citrix inventory is incomplete.
