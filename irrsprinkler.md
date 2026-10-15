# How Noah-MP Simulates Sprinkler Irrigation for Adelaide Parks

Notes on the Noah-MP sprinkler irrigation scheme in WRF, for `opt_irr = 1` and `opt_irrm = 1`.

```text
&noah_mp
 opt_irr  = 1,   ! trigger by root-zone soil moisture deficit, no seasonal limit
 opt_irrm = 1,   ! sprinkler only
/
```

> [!NOTE]
> The original cropland check (`FlagCropland`) was removed so that parks can be irrigated.
> See [IrrigationPrepareMod.F90#L69](phys/noahmp/src/IrrigationPrepareMod.F90#L69) and
> [NoahmpMainMod.F90#L83](phys/noahmp/src/NoahmpMainMod.F90#L83).

---

## Trigger conditions

[IrrigationPrepareMod.F90#L68-L73](phys/noahmp/src/IrrigationPrepareMod.F90#L68-L73)
calls `IrrigationTrigger` only when all of the following are true:

| Condition | Code variable | Parameter |
| --------- | ------------- | --------- |
| It is a soil time step | `FlagSoilProcess` | `soiltstep` in namelist |
| Irrigated fraction is large enough | `IrrigationFracGrid` (IRFRACT, from wrfinput) `>=` threshold | [IRR_FRAC](phys/noahmp/parameters/NoahmpTable.TBL#L518) |
| Rainfall is below the stop threshold | rainfall `<` threshold | [IR_RAIN](phys/noahmp/parameters/NoahmpTable.TBL#L526) (mm/h) |
| No irrigation event is in progress | sum of remaining amounts `== 0` | |

With `opt_irr = 1`,
[IrrigationTriggerMod.F90#L69-L78](phys/noahmp/src/IrrigationTriggerMod.F90#L69-L78)
adds no further restriction, so irrigation can occur at any time of the year.

[IrrigationTriggerMod.F90#L80-L91](phys/noahmp/src/IrrigationTriggerMod.F90#L80-L91)
sums the available water over the root-zone layers (`NumSoilLayerRoot`),
weighted by layer thickness.

> [!IMPORTANT]
> Only grid cells with `IRFRACT >= IRR_FRAC` (default 0.10) are irrigated.
> Set IRFRACT in every `wrfinput_d0X` after running `real.exe`, and set it to 0 elsewhere.

---

## Calculate irrigation amount

[IrrigationTriggerMod.F90#L93-L107](phys/noahmp/src/IrrigationTriggerMod.F90#L93-L107)

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
| `SoilMoistAvailMax` | Root-zone available water capacity | [REFSMC](phys/noahmp/parameters/NoahmpTable.TBL#L816) (field capacity) and [WLTSMC](phys/noahmp/parameters/NoahmpTable.TBL#L824) (wilting point) |
| `SoilMoistAvail` | Current root-zone available water | Current soil liquid water and WLTSMC |
| `SoilWatDeficitAllow` | Management allowable deficit | [IRR_MAD](phys/noahmp/parameters/NoahmpTable.TBL#L521) (default 0.60) |
| `IrrigationFracGrid` | Irrigated fraction of the grid cell | IRFRACT in wrfinput |
| `VegFrac` | Vegetation fraction | Depends on `dveg`; based on VEGFRA in wrfinput or on LAI |

If `SoilMoistAvail / SoilMoistAvailMax <= SoilWatDeficitAllow`, this step computes the
irrigation water needed to bring the root zone back to field capacity,
scaled to a grid mean by `IrrigationFracGrid` and `VegFrac`.

With `opt_irrm = 1`, if no sprinkler event is in progress
(`IrrigationAmtSprinkler == 0`), all of `IrrigationWater` is assigned to the
sprinkler and the event count is increased by 1.

> [!WARNING]
> Check that park cells have a vegetated `LU_INDEX` and a non-zero `VEGFRA`.
