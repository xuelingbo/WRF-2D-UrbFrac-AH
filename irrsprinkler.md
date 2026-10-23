# How Noah-MP Simulates Sprinkler Irrigation for Adelaide Parks

Notes on the Noah-MP sprinkler irrigation scheme in WRF, for `opt_irr = 1` and `opt_irrm = 1`.

```
&noah_mp
 opt_irr  = 1,   ! trigger by root-zone soil moisture deficit, no seasonal limit
 opt_irrm = 1,   ! sprinkler only
/
```

## Modification for Adelaide parks

> [!IMPORTANT]
> The original cropland check (`FlagCropland`) for sprinkler irrigation is replaced by a
> park check, `VegType == 8 .or. VegType == 9` (`VegType` = IVGTYP; in MODIFIED_IGBP_MODIS_NOAH, 8 = Woody Savannas, 9 = Savannas), so that parks can be irrigated.
> The check is applied consistently in four places:
>
> | File | What it controls |
> | ---- | ---------------- |
> | [IrrigationPrepareMod.F90#L70](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/IrrigationPrepareMod.F90#L70) | Whether `IrrigationTrigger` is called |
> | [NoahmpMainMod.F90#L84](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/NoahmpMainMod.F90#L84) | Whether `IrrigationSprinkler` applies water |
> | [EnergyMainMod.F90#L340](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/EnergyMainMod.F90#L340) | Sensible heat reduced by sprinkler evaporation (`HeatLatentIrriEvap`) |
> | [BalanceErrorCheckMod.F90#L115](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/BalanceErrorCheckMod.F90#L115) | Sprinkler water added to precipitation in the water balance check |
>
> Without the last two changes, park cells would not lose the sprinkler evaporation heat,
> and the water balance check would stop the model with
> `Error: Water budget problem in NoahMP LSM`.

---

## Trigger conditions

[IrrigationPrepareMod.F90#L69-L76](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/IrrigationPrepareMod.F90#L69-L76)
calls `IrrigationTrigger` only when all of the following are true:

| Condition | Code variable | Parameter |
| --------- | ------------- | --------- |
| It is a soil time step | `FlagSoilProcess` | `soiltstep` in namelist |
| It is a park cell | `VegType` (IVGTYP, from wrfinput) is 8 or 9 | |
| Irrigated fraction is large enough | `IrrigationFracGrid` (IRFRACT, from wrfinput) `>=` threshold | [IRR_FRAC](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/parameters/NoahmpTable.TBL#L518) |
| Rainfall is below the stop threshold | rainfall `<` threshold | [IR_RAIN](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/parameters/NoahmpTable.TBL#L526) (mm/h) |
| No irrigation event is in progress | sum of remaining amounts `== 0` | |

With `opt_irr = 1`,
[IrrigationTriggerMod.F90#L69-L78](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/IrrigationTriggerMod.F90#L69-L78)
adds no further restriction, so irrigation can occur at any time of the year.

[IrrigationTriggerMod.F90#L80-L91](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/IrrigationTriggerMod.F90#L80-L91)
sums the available water over the root-zone layers (`NumSoilLayerRoot`),
weighted by layer thickness.

---

## Calculate irrigation amount

[IrrigationTriggerMod.F90#L93-L107](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/src/IrrigationTriggerMod.F90#L93-L107)

```fortran
if ( (SoilMoistAvail/SoilMoistAvailMax) <= SoilWatDeficitAllow ) then
    IrrigationWater = (SoilMoistAvailMax - SoilMoistAvail) * IrrigationFracGrid * VegFrac
```

```fortran
! sprinkler irrigation amount (m) based on namelist choice
elseif ( (IrrigationAmtSprinkler == 0.0) .and. (OptIrrigationMethod == 1) ) then
    IrrigationAmtSprinkler = IrrigationWater
    IrrigationCntSprinkler = IrrigationCntSprinkler + 1
endif
```

| Variable | Meaning | Source |
| -------- | ------- | ------ |
| `SoilMoistAvailMax` | Root-zone available water capacity | [REFSMC](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/parameters/NoahmpTable.TBL#L816) (field capacity) and [WLTSMC](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/parameters/NoahmpTable.TBL#L824) (wilting point) |
| `SoilMoistAvail` | Current root-zone available water | Current soil liquid water and WLTSMC |
| `SoilWatDeficitAllow` | Management allowable deficit | [IRR_MAD](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH/blob/4f95d35f46b2bc7fdc7ed6300bd47ef73782cb7f/parameters/NoahmpTable.TBL#L521) (default 0.60) |
| `IrrigationFracGrid` | Irrigated fraction of the grid cell | IRFRACT in wrfinput |
| `VegFrac` | Vegetation fraction | Depends on `dveg`|

If `SoilMoistAvail / SoilMoistAvailMax <= SoilWatDeficitAllow`, this step computes the
irrigation water needed to bring the root zone back to field capacity,
scaled to a grid mean by `IrrigationFracGrid` and `VegFrac`. The water is applied over the whole grid cell, so the root zone recovers only about `VegFrac` of the deficit per event.

With `opt_irrm = 1`, if no sprinkler event is in progress
(`IrrigationAmtSprinkler == 0`), all of `IrrigationWater` is assigned to the
sprinkler and the event count is increased by 1.

> [!WARNING]
> Check that park cells have IVGTYP 8 or 9, non-zero `VegFrac` and `IRFRACT` >= `IRR_FRAC`.

---

## Download and Build WRF

Build on Flinders DeepThought HPC with [build_wrf_deepthought.sh](build_wrf_deepthought.sh).

Put the script in the folder where WRF should go, then run it on the **login node**:

```bash
cd /path/to/this/folder
bash build_wrf_deepthought.sh        # bash, not sbatch
```

The script runs in two stages:

| Stage | Where | What it does |
| ----- | ----- | ------------ |
| 1. Download | Login node (has internet) | Clones [WRF-2D-UrbFrac-AH](https://github.com/xuelingbo/WRF-2D-UrbFrac-AH) branch `dev-v4.8-Flinders` and all submodules (including the modified [noahmp](https://github.com/xuelingbo/noahmp-2D-UrbFrac-AH)) into `WRF-v4.8-Flinders/`, then submits itself with `sbatch` |
| 2. Compile | `general` partition | Loads the `WRF` module (compiler, MPI, NetCDF), sets `NETCDF`, configures with option 34 (GNU dmpar) and nesting 1 (basic), compiles `em_real` |

Check progress:

```bash
squeue -u $USER
tail -f build_wrf_<jobid>.log
```

The build succeeded if the log ends with `WRF built successfully`, and
`WRF-v4.8-Flinders/run/` contains `wrf.exe`, `real.exe`, `ndown.exe` and `tc.exe`.
If it fails, check `WRF-v4.8-Flinders/compile.log`.

To recompile without downloading again, run `sbatch build_wrf_deepthought.sh` instead.

