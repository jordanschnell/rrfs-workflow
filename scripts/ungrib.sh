##!/bin/sh -l

# Load modules
#source ${MODULE_FILE}

# Load modules for wgrib2
module purge
module use /lfs5/NAGAPE/wof/mpas/modules
module load build_jet_Rocky8_intel_smiol
#module load wgrib2/2.0.8

set -x

export LD_LIBRARY_PATH=/lfs5/NAGAPE/wof/miniconda3_RL/lib:${LD_LIBRARY_PATH}
export CPATH=/usr/include/tirpc:$CPATH

WGRIB2=/apps/wgrib2/2.0.8/intel/18.0.5.274/bin/wgrib2

echo "WGRIB2 SOURCE:"
#which wgrib2
which ${WGRIB2}


rm -rf $WORK_DIR/$FHR
mkdir -p $WORK_DIR/$FHR
cd $WORK_DIR/$FHR

y=`echo $INIT_TIME | cut -c 1-4`
y2=`echo $INIT_TIME | cut -c 3-4`
ymd=`echo $INIT_TIME | cut -c 1-8`
h=`echo $INIT_TIME | cut -c 9-10`

starttime_str=$(date -d "${ymd} ${h}:00 ${FHR} hours" +%Y-%m-%d_%H:%M:%S)
endtime_str=$(date -d "${ymd} ${h}:00 ${FHR} hours" +%Y-%m-%d_%H:%M:%S)
jul=$(date -d "${ymd} ${h}:00" +%j)

if [[ $INIT_SOURCE == "HRRR" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.raphrrr Vtable
  GRIB_FILE=${EXT_INIT_DIR}/${y2}${jul}${h}"0000"${FHR}
elif [[ $INIT_SOURCE == "RAP" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.raphrrr Vtable
  GRIB_FILE=${EXT_INIT_DIR}/${y2}${jul}${h}"0000"${FHR}  
elif [[ $INIT_SOURCE == "RRFS" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.RRFS Vtable
#  GRIB_FILE=${EXT_INIT_DIR}"/"${INIT_TIME}"/"${MEM}"/"${y2}${jul}${h}"0000"${FHR}
#  GRIB_FILE=${EXT_INIT_DIR}"/"${INIT_TIME}"/"${MEM}"/rrfs.t"${h}"z.natlev.f0"${FHR}".grib2"
#  GRIB_FILE=${EXT_INIT_DIR}"/rrfs_a."${ymd}"/"${h}"/"${MEM}"/rrfs.t"${h}"z.natlev.f0"${FHR}".grib2"
  GRIB_FILE=${EXT_INIT_DIR}"/rrfs."${ymd}"/"${h}"/rrfs.t"${h}"z.natlev.3km.f0"${FHR}".na.grib2"
elif [[ $INIT_SOURCE == "RRFS_EXT" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.RRFS Vtable
  GRIB_FILE=${EXT_INIT_DIR}/${ymd}${h}/${MEM}/rrfs.t${h}z.natlev.f0${FHR}.grib2
#  GRIB_FILE=${EXT_INIT_DIR}/${ymd}${h}/${MEM}/rrfs.t${h}z.natlev.3km.f0${FHR}.na.grib2  
elif [[ $INIT_SOURCE == "GFS" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.GFS_full Vtable
  GRIB_FILE=${EXT_INIT_DIR}/${y2}${jul}${h}"0000"${FHR}
elif [[ $INIT_SOURCE == "GEFS" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.GFSENS Vtable
  GRIB_FILE=${EXT_INIT_DIR}/${MEM}/${y2}${jul}${h}"0000"${FHR}
elif [[ $INIT_SOURCE == "MPAS" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.MPAS Vtable
  GRIB_FILE=${EXT_INIT_DIR}/mpas_rrfsa_nat_${ymd}${h}_f${FHR}.grib2
elif [[ $INIT_SOURCE == "MPAS_NSSL_RT" ]]; then
  ln -sf $FIX_DIR/WRFV4.0/Vtable.MPAS Vtable
  GRIB_FILE=${EXT_INIT_DIR}/MPAS-A_${ymd}${h}_RTf${FHR}.grib2
else
  echo "IC/LBC source not valid or not specified"
  exit 1
fi

echo "IC/LBC SOURCE: "${INIT_SOURCE}
echo "GRIB file: "${GRIB_FILE}
if [[ ! -e $GRIB_FILE ]]; then
  echo "GRIB file not found"
  exit 1
fi


if [[ $INTERP == 1 ]]; then

  if [[ $INIT_SOURCE == "RRFS" || $INIT_SOURCE == "RRFS_EXT" ]]; then

    # HRRR grid
    #grid_specs="lambert:-97.5:38.5 -122.719528:1799:3000.0 21.138123:1059:3000.0"

    # variation on 130 grid at 3 km
    #grid_specs="lambert:266:25.000000 234.862000:2000:3000.000000 17.281000:1480:3000.000000"
    grid_specs="lambert:266:25.000000 234.862000:2000:3000.000000 18.281000:1450:3000.000000"

    ${WGRIB2} ${GRIB_FILE} -set_bitmap 1 -set_grib_type c3 -new_grid_winds grid \
           -new_grid_vectors "UGRD:VGRD:USTM:VSTM:VUCSH:VVCSH"               \
           -new_grid_interpolation bilinear \
           -if "`cat ${FIX_DIR}/budget_fields.txt`" -new_grid_interpolation budget -fi \
           -if "`cat ${FIX_DIR}/neighbor_fields.txt`" -new_grid_interpolation neighbor -fi \
           -new_grid ${grid_specs} tmp.grib2

    # Merge vector field records
    ${WGRIB2} tmp.grib2 -not aerosol=Dust -new_grid_vectors "UGRD:VGRD:USTM:VSTM:VUCSH:VVCSH" -submsg_uv tmp2.grib2

    if [ -e tmp2.grib2 ] ; then
      ln -sf tmp2.grib2 GRIBFILE.AAA
    else
      echo "tmp2.grib2 not created; exiting"
      exit 1
    fi

  fi

  if [[ $INIT_SOURCE == "RAP" ]]; then

    # Interpolate to Lambert conformal grid

    grid_specs_20km="lambert:-97.5:38.5 -133.174:449:20000.0 5.47114:299:20000.0"

    ${WGRIB2} ${GRIB_FILE} -set_bitmap 1 -set_grib_type c3 -new_grid_winds grid \
           -new_grid_vectors "UGRD:VGRD:USTM:VSTM:VUCSH:VVCSH"               \
           -new_grid_interpolation neighbor                                  \
           -new_grid ${grid_specs_20km} tmp.grib2

    # Merge vector field records
    ${WGRIB2} tmp.grib2 -new_grid_vectors "UGRD:VGRD:USTM:VSTM:VUCSH:VVCSH" -submsg_uv 20km_grid.grib2

    ln -sf 20km_grid.grib2 GRIBFILE.AAA

  fi

else

  ln -sf $GRIB_FILE GRIBFILE.AAA  

fi

ln -sf $EXEC_DIR/ungrib.exe .

cp $NAMELIST_DIR/namelist.wps .
sed -i "s/STARTTIME/$starttime_str/g" namelist.wps
sed -i "s/ENDTIME/$endtime_str/g" namelist.wps
sed -i "s|GEOG_PATH|$WPS_GEOG_PATH|g" namelist.wps
sed -i "s/INIT_SOURCE/$INIT_SOURCE/g" namelist.wps

./ungrib.exe

outtime_str=$(date -d "${ymd} ${h}:00 ${FHR} hours" +%Y-%m-%d_%H)
outfile=${INIT_SOURCE}":"${outtime_str}
if [[ -e $outfile ]]; then
  echo "Created "${outfile}" successfully"
  mv $outfile $WORK_DIR
  exit 0
else
  echo "Failed to create "${outfile}
  exit 1
fi

