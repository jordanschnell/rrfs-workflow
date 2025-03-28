import re
import shutil
import subprocess
import sys
from abc import abstractmethod, ABC
from datetime import datetime, timezone
from functools import cached_property
from pathlib import Path
from typing import Literal, Iterable, Any

import esmpy
import numpy as np
import pandas as pd
from pydantic import BaseModel, computed_field
from pyremap import MpasCellMeshDescriptor

from regrid_wrapper.context.comm import COMM, reconcile_bounds
from regrid_wrapper.context.logging import LOGGER
from regrid_wrapper.esmpy.field_wrapper import (
    GridSpec,
    NcToGrid,
    NcToField,
    FieldWrapper,
    GridWrapper,
    open_nc,
    Dimension,
    DimensionCollection,
    set_variable_data,
    HasNcAttrsType,
    copy_nc_variable,
)

_LOGGER = LOGGER.getChild("mpas-regrid")


class AbstractRaveField(ABC, BaseModel):
    name: str
    attrs: dict[str, Any]
    fill_value: float
    dtype: Any
    num_cells: int

    @computed_field
    @cached_property
    def time_dimension(self) -> Dimension:
        return Dimension(
            name=("Time",),
            size=12,
            lower=0,
            upper=12,
            staggerloc=esmpy.StaggerLoc.CENTER,
            coordinate_type="time",
        )

    @computed_field
    @cached_property
    def nkfire_dimension(self) -> Dimension:
        return Dimension(
            name=("nkemit",),
            size=20,
            lower=0,
            upper=20,
            staggerloc=esmpy.StaggerLoc.CENTER,
            coordinate_type="level",
        )

    def create_ncells_dimension(self, bounds: tuple[int, int]) -> Dimension:
        return Dimension(
            name=("nCells",),
            size=self.num_cells,#225636, #130333,  # tdk: pull from origin,
            lower=bounds[0],
            upper=bounds[1],
            staggerloc=esmpy.MeshLoc.ELEMENT,
            coordinate_type="cell",
        )

    @abstractmethod
    def create_dimension_collection(
        self, ncells_bounds: tuple[int, int]
    ) -> DimensionCollection: ...

    @abstractmethod
    def reshape_field_data(self, target: np.ndarray) -> np.ndarray: ...


class RaveField2d(AbstractRaveField):

    def create_dimension_collection(
        self, ncells_bounds: tuple[int, int]
    ) -> DimensionCollection:
        return DimensionCollection(
            value=(self.time_dimension, self.create_ncells_dimension(ncells_bounds))
        )

    def reshape_field_data(self, target: np.ndarray) -> np.ndarray:
        return target.reshape(1, -1)


class RaveField3d(AbstractRaveField):

    def create_dimension_collection(
        self, ncells_bounds: tuple[int, int]
    ) -> DimensionCollection:
        return DimensionCollection(
            value=(
                self.create_ncells_dimension(ncells_bounds),
                self.nkfire_dimension,
                self.time_dimension,
            )
        )

    def reshape_field_data(self, target: np.ndarray) -> np.ndarray:
        return target.reshape(1, -1, 1)


class RaveToMpasRegridContext(BaseModel):
    src_path: Path
    dst_path: Path
    new_dst_path: Path
    desc_stats_out: Path
    tmp_path: Path
    weight_path: Path
    scrip_path: Path
    num_cells: int
    mesh_name: str
    rank: int = COMM.rank

    @computed_field
    @cached_property
    def rave_fields(self) -> tuple[AbstractRaveField, ...]:
        field_names = ("PM25-PRI","PM10-PRI")
        rave_fields = []
        with open_nc(self.src_path, mode="r") as ds:
            for field_name in field_names:
                var = ds.variables[field_name]
                init_data = {
                    "name": field_name,
                    "attrs": self._get_nc_attrs_(var),
                    "fill_value": -1.0,
                    "dtype": var.dtype,
                    "num_cells": self.num_cells,
                }
                if field_name in ("PM25-PRI","PM10-PRI"):
                    app = RaveField3d.model_validate(init_data)
                else:
                    raise NotImplementedError(field_name)
                rave_fields.append(app)
        _LOGGER.debug(f"{rave_fields=}")
        return tuple(rave_fields)

    @staticmethod
    def _get_nc_attrs_(src: HasNcAttrsType) -> dict[str, Any]:
        # tdk: does valid_range matter?
        exclude = ("coordinates", "valid_range")
        return {
            ii: getattr(src, ii)
            for ii in src.ncattrs()
            if not ii.startswith("_") and ii not in exclude
        }


class FileDesc(BaseModel):
    path: Path
    origin: Literal["src", "dst"]
    field_names: tuple[str, ...]


class RaveToMpasRegridProcessor:

    def __init__(self, context: RaveToMpasRegridContext) -> None:
        self.context = context

        self._regridder: esmpy.Regrid | None = None
        self._dst_field: esmpy.Field | None = None
        self._src_gwrap: GridWrapper | None = None

    def initialize(self) -> None:
        _LOGGER.info(f"initialize: {self.context=}")
        esmpy.Manager(debug=True)

        if not self.context.scrip_path.exists() and self.context.rank == 0:
            _LOGGER.info("writing mpas scrip grid")
            mpas_desc = MpasCellMeshDescriptor(
                str(self.context.dst_path), self.context.mesh_name + ".init"
            )
            mpas_desc.to_scrip(str(self.context.scrip_path))

        print("create source grid")
        self._src_gwrap = NcToGrid(
            path=self.context.src_path,
            spec=GridSpec(
                x_center="XLONG",
                y_center="XLAT",
                x_dim=("west_east",),
                y_dim=("south_north",),
                x_corner=None, #"XLONG_C",
                y_corner=None, #"XLAT_C",
                x_corner_dim=None, #("west_east_stag",),
                y_corner_dim=None, #("south_north_stag",),
            ),
        ).create_grid_wrapper()

        _LOGGER.info("create source field")
        src_fwrap = self.create_src_field_wrapper(self.context.rave_fields[0].name)

        _LOGGER.info("create destination mesh")
        dst_mesh = esmpy.Mesh(
            filename=str(self.context.scrip_path), filetype=esmpy.FileFormat.SCRIP
        )

        # Add in ndbounds here
        _LOGGER.info("create destination field")
        self._dst_field = esmpy.Field(
            dst_mesh, name="dst", meshloc=esmpy.MeshLoc.ELEMENT,ndbounds=(20,12)
        )
       

        _LOGGER.info("create regridder")
        if self.context.weight_path.exists():
            _LOGGER.info("create regridder from file")
            self._regridder = esmpy.RegridFromFile(
                srcfield=src_fwrap.value,
                dstfield=self._dst_field,
                filename=str(self.context.weight_path),
            )
        else:
            _LOGGER.info("create regridder in-memory")
            self._regridder = esmpy.Regrid(
                srcfield=src_fwrap.value,
                dstfield=self._dst_field,
                regrid_method=esmpy.RegridMethod.BILINEAR,
                unmapped_action=esmpy.UnmappedAction.IGNORE,
                ignore_degenerate=False,
                filename=str(self.context.weight_path),
            )

    def run(self) -> None:
        _LOGGER.info("apply regridding")

        _LOGGER.info("create output file")
        ncells_size = self.context.num_cells #130333  # tdk: pull from origin
        if self.context.rank == 0:
            with open_nc(self.context.new_dst_path, mode="w", parallel=False) as dst_nc:
                dst_nc.createDimension("nCells", ncells_size)
                dst_nc.createDimension("nkemit", 20)
                dst_nc.createDimension("Time",12)
                dst_nc.setncattr("created_at", str(datetime.now(timezone.utc)))
                dst_nc.setncattr("src_path", str(self.context.src_path))
                dst_nc.setncattr("dst_path", str(self.context.dst_path))
                with open_nc(self.context.dst_path, mode="r", parallel=False) as src_nc:
                    for varname in ("latCell", "lonCell"):
                        copy_nc_variable(src_nc, dst_nc, varname, copy_data=True)

        regridder = self.get_regridder()
        for rave_field in self.context.rave_fields:
            _LOGGER.info(f"regridding {rave_field.name=}")
            src_fwrap = self.create_src_field_wrapper(field_name=rave_field.name)
            dst_field = self.get_dst_field()
            # tdk: any more qa stuff? minimum threshold?
            dst_field.data.fill(0.0)
            regridder(src_fwrap.value, dst_field)

            # tdk: support NcToMesh
            local_bounds = (dst_field.lower_bounds[0], dst_field.upper_bounds[0])
            reconciled_bounds = reconcile_bounds(local_bounds)
            dims = rave_field.create_dimension_collection(reconciled_bounds)
            _LOGGER.info(f"{dims=}")
            _LOGGER.info(f"writing field to netcdf")
            with open_nc(self.context.new_dst_path, mode="a") as ds:
                var = ds.createVariable(
                    rave_field.name,
                    rave_field.dtype,
                    [dim.name[0] for dim in dims.value],
                    fill_value=rave_field.fill_value,
                )
                for k, v in rave_field.attrs.items():
                    setattr(var, k, v)
                set_variable_data(
                    var,
                    dims,
                    dst_field.data,
                    collective=True,
                )

            src_fwrap.value.destroy()
            del src_fwrap

        if self.context.rank == 0:
            field_names = tuple(ii.name for ii in self.context.rave_fields)
            targets = [
                FileDesc(
                    path=self.context.new_dst_path,
                    origin="dst",
                    field_names=field_names,
                ),
                FileDesc(
                    path=self.context.src_path,
                    origin="src",
                    field_names=field_names,
                ),
            ]
            data_frame = self.create_desc_stuff(targets)
            data_frame.to_csv(self.context.desc_stats_out, index=False)

    def finalize(self) -> None:
        _LOGGER.info("finalizing")

    def create_desc_stuff(self, targets: Iterable[FileDesc]) -> pd.DataFrame:
        _LOGGER.info("entering create_desc_stuff")
        if self.context.rank > 0:
            raise ValueError

        to_concat = []
        for target in targets:
            with open_nc(target.path, mode="r", parallel=False) as ds:
                for varname in target.field_names:
                    data = ds.variables[varname][:].filled(np.nan).ravel()
                    data_frame = pd.DataFrame.from_dict({varname: data})
                    desc = data_frame.describe()
                    adds = {
                        varname: [
                            data_frame[varname].sum(),
                            data_frame[varname].isnull().sum(),
                            target.origin,
                            target.path,
                        ]
                    }
                    desc = pd.concat(
                        [
                            desc,
                            pd.DataFrame(
                                data=adds, index=["sum", "count_null", "origin", "path"]
                            ),
                        ]
                    )
                    to_concat.append(desc)
        ret = pd.concat([ii.transpose() for ii in to_concat])
        ret.index.name = "field_name"
        ret.reset_index(inplace=True)
        _LOGGER.info("exiting create_desc_stuff")
        return ret
# Add ungridded dimension for level dimension
    def create_src_field_wrapper(self, field_name: str) -> FieldWrapper:
        _LOGGER.info("create source field")
        src_fwrap = NcToField(
            path=self.context.src_path,
            name=field_name,
            gwrap=self.get_src_gwrap(),
            dim_time=("Time",),
            dim_level=("bottom_top",),
        ).create_field_wrapper()
        src_data = src_fwrap.value.data
        src_data[:] = np.where(src_data < 0.0, 0.0, src_data)
        return src_fwrap

    def get_src_gwrap(self) -> GridWrapper:
        if self._src_gwrap is None:
            raise ValueError
        return self._src_gwrap

    def get_dst_field(self) -> esmpy.Field:
        if self._dst_field is None:
            raise ValueError
        return self._dst_field

    def get_regridder(self) -> esmpy.Regrid:
        if self._regridder is None:
            raise ValueError
        return self._regridder


def main() -> None:
    workdir      = sys.argv[1]
    mesh_name    = sys.argv[2]
    weight_path  = Path(sys.argv[3])
    rave_path    = Path(sys.argv[4])
    cycle        = sys.argv[5]
    new_dst_path = sys.argv[6] 
    dst_path     = Path(workdir + "/" + mesh_name + ".init.nc")       # Name of init file
    scrip_path   = Path(workdir + "/mpas_scrip.nc")

    with open_nc(dst_path, mode="r", parallel=False) as src_nc:
        foo = src_nc.variables['latCell']
        num_cells = len(foo)
        desc_stats_out = Path("desc_stats-{cycle}.csv")

        context = RaveToMpasRegridContext(
            src_path=rave_path,
            dst_path=dst_path,
            new_dst_path=new_dst_path,
            desc_stats_out=desc_stats_out,
            tmp_path=workdir,
            weight_path=weight_path,
            scrip_path=scrip_path,
            num_cells=num_cells,
            mesh_name=mesh_name,
        )
        processor = RaveToMpasRegridProcessor(context=context)
        processor.initialize()
        processor.run()
        processor.finalize()

    _LOGGER.info("success")


if __name__ == "__main__":
    main()
