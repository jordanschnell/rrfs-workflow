"""
Using https://github.com/MPAS-Dev/pyremap
Based on this example: https://github.com/MPAS-Dev/pyremap/blob/main/examples/make_mpas_to_lat_lon_mapping.py

pyremap creates temporary SCRIP files for the src and dst
and then runs ESMF_RegridWeightGen with those
"""
import datetime
from pathlib import Path
import sys
import os
import numpy as np
import xarray as xr
#
pyremap_path = "/mnt/lfs5/BMC/rtwbl/Jordan/src/MPAS/input/scripts/pyremap"
sys.path.append(pyremap_path) # "/mnt/lfs5/BMC/rtwbl/Jordan/src/MPAS/input/scripts/pyremap")
from pyremap import MpasCellMeshDescriptor, Remapper, LatLonGridDescriptor, LatLon2DGridDescriptor
#
#
#
def get_src(d=0.1):  # resolution (deg)
    hd = d / 2
    latc = np.arange(-90 + hd, 90 - hd + d, d)
    lonc = np.arange(-180 + hd, 180 - hd + d, d)
    lat = np.arange(-90, 90 + d, d)
    lon = np.arange(-180, 180 + d, d)
    assert lat.size == latc.size + 1
    assert lon.size == lonc.size + 1
    return LatLonGridDescriptor.create(lat, lon, units="degrees")
    # Seems like we need to use the edges here, since otherwise it complained about
    # some dst cells not overlapping src
#
# ------------------
#
src_file1 = str(sys.argv[1])
src_file2 = str(sys.argv[2])
ps = [
     Path(src_file1),
     Path(src_file2),
]
src_reg  = sys.argv[3]
src_lat  = sys.argv[4]
src_lon  = sys.argv[5]
grid_file = sys.argv[6]
grid_name = grid_file[:-3]
dst_reg = sys.argv[7]
method = sys.argv[8]
p_weights1 = Path(sys.argv[9])
p_weights2 = Path(sys.argv[10])
remake_weights = sys.argv[11]
outfile=sys.argv[12]
tmpdir=Path(sys.argv[13])
#
p_mpas_grid = Path(grid_file) # e.g., na15km.init.nc
#
dst = MpasCellMeshDescriptor(p_mpas_grid, grid_file)
dst.regional = dst_reg
#
remapped = []
#
d, p = 0.1, ps[0]
src = get_src(d)
src.regional = src_reg
remapper = Remapper(src, dst, p_weights1)
if not p_weights1.is_file():
    remapper.esmf_build_map(method=method, mpi_tasks=1, include_logs=True,tempdir=tmpdir)
ds_data = xr.open_dataset(src_file1)
remapped.append(remapper.remap(ds_data))
#
# ------
#
d, p = 0.05, ps[1]
src = get_src(d)
src.regional = src_reg
remapper = Remapper(src, dst, p_weights2)
if not p_weights2.is_file():
    remapper.esmf_build_map(method=method, mpi_tasks=1, include_logs=True, tempdir=tmpdir)
ds_data = xr.open_dataset(src_file2)
remapped.append(remapper.remap(ds_data))
#
ds = xr.merge(remapped)
#
assert set(ds.coords) == {"time", "latCell", "lonCell"}
#
# Preserve special values
specials = {
    "albedo_drag": [
        1e-6,
    ],
    "uthres": [
        999.0,
        1.0,
    ],
    "uthres_sg": [
        1.0,
    ],
    "sep": [
        0.0,
    ],
    # "LAI": [],
    # "GVF": [],
    # "PC": [],
    # "fveg": [],
    # "fbare": [],
    "feff": [
        1e-10,
        1e-5,
    ],
    # "lcbare": [],
    # "lcveg": [],
}
for vn, sps in specials.items():
    for sp in sps: 
        ds[vn] = ds[vn].where(~np.isclose(ds[vn], sp), sp)

for a in ["date_created", "convention", "conventions"]:
    del ds.attrs[a]
#
ds.attrs["history"] = "\n".join(
    [
        f"created: {datetime.datetime.now(datetime.timezone.utc)}",
        f"from: {Path(__file__).resolve().as_posix()}",
        f"regrid method: {method!r}",
        f"source file_1: {src_file1!r}",
        f"source file_2: {src_file2!r}",
    ]
)
#
for vn in ds.data_vars:
    ds[vn] = ds[vn].astype(np.float32)
#
#encoding = {vn: {"zlib": True, "complevel": 1} for vn in ds.data_vars}
ds.to_netcdf(outfile) #, encoding=encoding)
#
