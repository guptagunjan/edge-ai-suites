<!-- SPDX-FileCopyrightText: (C) 2026 Intel Corporation -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Example — Attach a console and compare two models

## Invocation

```
/loitering-detection-ui attach a mission console to the running loitering-detection
deployment at ./loitering-detection, publish it on port 9443, and let me compare
two of the installed detection models on the same video
```

The identifier is the skill's front-matter `name`, lower-case. The repository
containing `.github/skills/loitering-detection-ui/` must be open as a workspace
folder for the command to resolve. The skill may also be engaged by description,
for example "add an operator dashboard to the loitering-detection stack".

## Expected behaviour

1. Confirms the application is running and that its tracked files are clean.
2. Confirms the released pipelines expose `detection-properties`, so no change to
   the pipeline configuration is required.
3. Asks the parameter questions in a single message.
4. Generates the console into an addon directory outside the application tree.
5. Deploys it from its own compose file, joining the application's network as an
   external network.
6. Runs the acceptance gate, including the live phase on every available device.

## Expected result

- The console answers at `https://<HOST_IP>:9443/`.
- The application's own interface is unchanged and still reachable on port 443.
- `git status` in the application repository reports no modified tracked file.
- The model selectors list exactly the models present in the model store.
- Selecting two models and starting comparison mode yields two panels with live
  annotated video and independent FPS, dwell and loiter figures.
- Drawing a zone and applying it changes the analytics immediately, without the
  video being interrupted.

## Follow-up

```
add the model at /opt/models/my-detector/FP16/my-detector.xml to the store and
compare it against the detector the application ships with
```

The skill installs the model with `scripts/add-model.sh`, refreshes the catalogue
and starts the comparison. No code, configuration or documentation in the skill
names any model.
