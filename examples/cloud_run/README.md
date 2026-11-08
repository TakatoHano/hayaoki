# Cloud Run

Files: `Dockerfile`, `service.yaml`, and [`../puma.rb`](../puma.rb) (copy it to `config/puma.rb`).

What the settings do:

| Setting | Where | Effect |
| --- | --- | --- |
| `bootsnap precompile` | `Dockerfile` | the bootsnap cache is built at image build, not at the first boot |
| `run.googleapis.com/startup-cpu-boost` | `service.yaml` | 2x the vCPU limit during startup and 10 s after; billed [C3] |
| `startupProbe` on `/up` | `service.yaml` | 1 s period, 60 failures allowed (60 s budget). The default is a TCP probe [C2] |
| `containerConcurrency: 8` | `service.yaml` | equal to `RAILS_MAX_THREADS` in the `Dockerfile`: one Puma process, one thread per request |
| `minScale: "0"` | `service.yaml` | scale to zero. Use min instances if cold starts are not acceptable |

Cloud Run sets `K_SERVICE`, `K_REVISION` and `K_CONFIGURATION`, which the recorder logs as `platform` [C1]. The container must listen within 4 minutes [C1].

## Steps

1. Add the gem and the `config/boot.rb` lines from [`../README.md`](../README.md#add-the-recorder-to-your-app). Make sure `/up` returns 2xx.
2. Copy `Dockerfile` into the app root and `puma.rb` to `config/puma.rb`. Build and push the image.
3. Edit the image and secret in `service.yaml`, then `gcloud run services replace service.yaml --region REGION`.
4. Send requests so that new instances start (for example, deploy a new revision and request it once).
5. Collect the lines and summarize:

```sh
gcloud logging read 'jsonPayload.hayaoki="cold_start"' --format=json > cold.json
hayaoki cold-start-report --group-by revision cold.json
```

`cold-start-report` accepts the `jsonPayload` export directly. `hayaoki cold-start-report -h` lists the options (`--group-by`, `--since`, `--until`, `--format`, `--exclude-proactive`).
