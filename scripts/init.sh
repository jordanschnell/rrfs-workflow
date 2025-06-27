#!/bin/sh -l

# Load modules

#source ${MODULE_FILE}

module purge
module use ${MODULE_PATH}
module load ${MODULE_FILE}
module load nco
module list

ulimit -s unlimited

set -x

rm -rf $WORK_DIR
mkdir -p $WORK_DIR
cd $WORK_DIR

echo "INIT_TIME = $INIT_TIME"
echo "INIT_SOURCE = $INIT_SOURCE"
echo "RESET_VEG_MIN_AND_MAX = $RESET_VEG_MIN_AND_MAX"

ymd=`echo $INIT_TIME | cut -c 1-8`
h=`echo $INIT_TIME | cut -c 9-10`

starttime_str=$(date -d "${ymd} ${h}:00" +%Y-%m-%d_%H:%M:%S)
endtime_str=$(date -d "${ymd} ${h}:00" +%Y-%m-%d_%H:%M:%S)

ln -sf ${UNGRIB_DIR}/${INIT_SOURCE}:${starttime_str:0:13} .
ln -sf $FIX_DIR/${MODEL_NAME}.static.nc .
ln -sf $FIX_DIR/${MODEL_NAME}.graph.info.part.120 .
ln -sf $FIX_DIR/${MODEL_NAME}.graph.info.part.800 .
ln -sf $FIX_DIR/${MODEL_NAME}.graph.info.part.1200 .
ln -sf $FIX_DIR/QNWFA_QNIFA_SIGMA_MONTHLY.dat .
ln -sf $EXEC_DIR/init_atmosphere_model .

LBC_INTERVAL_MIN=$((LBC_INTERVAL*3600))

cp $NAMELIST_DIR/namelist.init_atmosphere .
sed -i "s/STARTTIME/$starttime_str/g" namelist.init_atmosphere
sed -i "s/ENDTIME/$endtime_str/g" namelist.init_atmosphere
sed -i "s/INIT_CASE/7/g" namelist.init_atmosphere
sed -i "s/INIT_SOURCE/$INIT_SOURCE/g" namelist.init_atmosphere
sed -i "s/LBC_INTERVAL/$LBC_INTERVAL_MIN/g" namelist.init_atmosphere
sed -i "s|GEOG_PATH|$WPS_GEOG_PATH|g" namelist.init_atmosphere
sed -i "s|FIX_DIR|$FIX_DIR|g" namelist.init_atmosphere

if [[ $INIT_SOURCE == "HRRR" ]]; then
  sed -i "s/NFGLEVELS/51/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/9/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "RAP" ]]; then
  sed -i "s/NFGLEVELS/51/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/9/g" namelist.init_atmosphere  
elif [[ $INIT_SOURCE == "RAP_POST_DFI" ]]; then
  sed -i "s/NFGLEVELS/51/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/9/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "RRFS" || $INIT_SOURCE == "RRFS_EXT" ]]; then
  sed -i "s/NFGLEVELS/66/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/9/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "GFS" ]]; then
  sed -i "s/NFGLEVELS/57/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/4/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "GEFS" ]]; then
  sed -i "s/NFGLEVELS/32/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/4/g" namelist.init_atmosphere
else
  echo "IC/LBC source not valid or not specified"
  exit 1
fi

cp $NAMELIST_DIR/streams.init_atmosphere .
sed -i "s/LBC_INTERVAL/$LBC_INTERVAL/g" streams.init_atmosphere

srun init_atmosphere_model

initcount=$(ls *init.nc | wc -l)
if (( $initcount == 1 )); then
  echo "Created an init file successfully"
#  exit 0
else
  echo "Failed to create an init file"
  exit 1
fi

if [[ $RESET_VEG_MIN_AND_MAX == 1 ]]; then
  echo "Obtaining shdmin and shdmax from fix files"
  cp $FIX_DIR/shdmin.${MODEL_NAME}.nc .
  cp $FIX_DIR/shdmax.${MODEL_NAME}.nc .
  ncks -A -v shdmin shdmin.${MODEL_NAME}.nc ${MODEL_NAME}.init.nc
  ncks -A -v shdmax shdmax.${MODEL_NAME}.nc ${MODEL_NAME}.init.nc
#  echo "Obtaining vegfra from fix files"
#  cp $FIX_DIR/vegfra.${MODEL_NAME}.nc .
#  ncks -A -v vegfra vegfra.${MODEL_NAME}.nc ${MODEL_NAME}.init.nc
fi

if [ "${AEROSOL_INIT_FILE}" ]; then
  echo "Obtaining water- and ice-friendly aerosols from another source"
  if [[ ! -e $AEROSOL_INIT_FILE ]]; then
    echo "Not found:  ${AEROSOL_INIT_FILE}"
  else
    echo "AEROSOL_INIT_FILE:  ${AEROSOL_INIT_FILE}"
    ncks -A -v nwfa ${AEROSOL_INIT_FILE} ${MODEL_NAME}.init.nc
    ncks -A -v nifa ${AEROSOL_INIT_FILE} ${MODEL_NAME}.init.nc
  fi
fi

exit 0
