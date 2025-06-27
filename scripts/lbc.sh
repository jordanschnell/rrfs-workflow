#!/bin/sh -l


# Load modules
#source ${MODULE_FILE}
module purge
module use ${MODULE_PATH}
module load ${MODULE_FILE}
module list


#rm -rf $WORK_DIR
mkdir -p $WORK_DIR
cd $WORK_DIR

ymd=`echo $INIT_TIME | cut -c 1-8`
h=`echo $INIT_TIME | cut -c 9-10`

starttime_str=$(date -d "${ymd} ${h}:00 ${FCST_START} hours" +%Y-%m-%d_%H:%M:%S)
endtime_str=$(date -d "${ymd} ${h}:00 ${FCST_LENGTH} hours" +%Y-%m-%d_%H:%M:%S)

echo "starttime_str=${starttime_str}"
echo "endtime_str=${endtime_str}"

ln -sf $UNGRIB_DIR/$INIT_SOURCE* .
ln -sf $INIT_DIR/${MODEL_NAME}.init.nc .
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
sed -i "s/INIT_CASE/9/g" namelist.init_atmosphere
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
elif [[ $INIT_SOURCE == "RRFS" || $INIT_SOURCE == "RRFS_EXT" ]]; then
  sed -i "s/NFGLEVELS/66/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/9/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "GFS" ]]; then
  sed -i "s/NFGLEVELS/57/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/4/g" namelist.init_atmosphere
elif [[ $INIT_SOURCE == "GEFS" ]]; then
  sed -i "s/NFGLEVELS/57/g" namelist.init_atmosphere
  sed -i "s/NFGSOILLEVELS/4/g" namelist.init_atmosphere
else
  echo "IC/LBC source not valid or not specified"
  exit 1
fi

cp $NAMELIST_DIR/streams.init_atmosphere_lbc streams.init_atmosphere
sed -i "s/LBC_INTERVAL/$LBC_INTERVAL/g" streams.init_atmosphere

srun init_atmosphere_model

lbccount=$(ls *lbc*.nc | wc -l)
lbcneed=$(( FCST_LENGTH/LBC_INTERVAL + 1 ))
if (( $lbccount == $lbcneed )); then
  echo "Created all lbc files successfully"
  exit 0
else
  echo "Failed to create one or more lbc files"
  exit 1
fi

