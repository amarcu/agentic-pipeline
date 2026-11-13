# The editor loop — recipes

## Reachability

**GUI editor already open.** It registers with the CLI once the project has `com.unity.pipeline`.

```
unity status --format json --project-path <project>      # wait for state "ready"
unity command eval "return Application.unityVersion;" --project-path <project>
```

**Persistent headless editor — the pipeline host.** Launch the editor binary directly in batch
mode and *omit* `-quit` so it stays resident and serves the Pipeline API. The binary is under the
`location` that `unity editors --installed --format json` reports. A batch editor serves commands
but is **not** listed by `unity status`; confirm with `unity list`:

```
"<location>/Contents/MacOS/Unity" -batchmode -nographics -projectPath <project> -logFile <log> &
unity list --project-path <project>                      # tools present = reachable
```

It holds a licence seat while resident. Stop it by PID when done. Do not run it while the
`unity test` gate is running against the same project — one Personal seat.

**Pipeline package missing.** `unity pipeline install --project-path <project>` — edits
`Packages/manifest.json`; must-ask in StarBonk, so a human runs it once.

## Capture and the half-size check

```
unity command screenshot --output <dir>/NN-<what>.png --width 1920 --height 1080 --project-path <project>
sips -Z 960 <dir>/NN-<what>.png --out <dir>/NN-<what>.half.png
```

Read both. Judge palette and lighting at full size; silhouette and readability at
half size. Name the region in every judgement.

## Eval snippets — parameters only, never structure

Find the target, change one parameter group, return something checkable:

```
unity command eval "var go = GameObject.Find(\"<name>\"); var ps = go.GetComponent<ParticleSystem>(); var m = ps.main; m.startColor = new Color(0.2f, 1f, 0.9f); m.startSize = 0.35f; return m.startColor.ToString();" --project-path <project>
```

```
unity command eval "var r = GameObject.Find(\"<name>\").GetComponent<Renderer>(); var mpb = new MaterialPropertyBlock(); r.GetPropertyBlock(mpb); mpb.SetColor(\"_EmissionColor\", new Color(0.2f, 1f, 0.9f) * 4f); r.SetPropertyBlock(mpb); return \"ok\";" --project-path <project>
```

Never in an eval: `new GameObject`, `Instantiate` of a prefab into the scene, `SetParent`,
`Destroy` on anything you did not create this run, `AssetDatabase.CreateAsset`,
`EditorSceneManager.SaveScene`. Those are hierarchy or asset structure — must-ask.

Shader and HLSL files are written with `Write`/`Edit` under the project's art paths; the editor
recompiles on focus or on `unity command eval "UnityEditor.AssetDatabase.Refresh(); return 1;"`.

## Project notes

A project's own facts — renderer and package versions, assets that are missing, capture tooling on
its side — go in a `project-notes-<project>.md` beside this file, and are read with it. Keep them
out of this file, which is the same for every project.
