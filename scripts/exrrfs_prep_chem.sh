#!/usr/bin/env bash
#
# Author: Jordan Schnell, CIRES/NOAA GSL
#
# This script prepares the emissions for an MPAS Aerosols simulation based on 
# user selections/task name, MPAS domain, and time period.
#
# The script first checks to see if emissions are already available 
# (regridded for the domain and time period) and links to the ${DATA} (i.e., the main run directory)
# If emissions are not available, the program attempts to create them.
#
## Required Input Arguments
#
# 1. INTERP_METHOD             -- likely a metatask variable for each input type, determines interpolation method
# 2. EMIS_SECTOR_TO_PROCESS    -- which emission sector is this task performing? (anthro, pollen, dust)
# 3. ANTHRO_EMISINV            -- undecided, may merge for custom dataset, or leave option to combine
# 4. DATADIR_CHEM             -- location of interpolated files, ready to be used
# 5. MESH_NAME                -- name of the MPAS domain, required to know if we have weights or data intepolated to the domain 
# 6. FCST_LENGTH               -- nhours of forecast
#
declare -rx PS4='+ $(basename ${BASH_SOURCE[0]:-${FUNCNAME[0]:-"Unknown"}})[${LINENO}]${id}: '
set -x
cpreq=${cpreq:-cpreq}
#
LS=/bin/ls
LN=/bin/ln
RM=/bin/rm
MKDIR=/bin/mkdir
CP=/bin/cp
MV=/bin/mv
ECHO=/bin/echo
CAT=/bin/cat
GREP=/bin/grep
CUT=`which cut`
AWK="/bin/gawk --posix"
SED=/bin/sed
DATE=/bin/date
# 
# ... Go to the main run directory
cd ${DATA}
#
# ... Set some date variables
#
timestr=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%Y-%m-%d_%H.%M.%S)
# Set some date information based on the cycle time
YYYY=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%Y)
YYYY_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%Y)
MM=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%m)
MM_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%m)
DD=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%d)
DD_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%d)
HH=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%H)
HH_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%H)
DOW=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%A)  # 1-7, Monday-Sunday
DOW_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours " +%A)  # 1-7, Monday-Sunday
# Current and previous day calculation
current_day=`${DATE} -d "${YYYY}${MM}${DD}"`
current_hh=`${DATE} -d ${HH} +"%H"`
#
prev_hh=`${DATE} -d "$current_hh -24 hour" +"%H"`
previous_day=`${DATE} '+%C%y%m%d' -d "$current_day-1 days"`
previous_day="${previous_day} ${prev_hh}"
#
if [[ ${DOW} -le 5 ]]; then
   DOW_STRING=weekdy
elif [[ ${DOW} -eq 6 ]]; then
   DOW_STRING=satdy
else
   DOW_STRING=sundy
fi
if [[ ${DOW_END} -le 5 ]]; then
   DOW_END_STRING=weekdy
elif [[ ${DOW_END} -eq 6 ]]; then
   DOW_END_STRING=satdy
else
   DOW_END_STRING=sundy
fi
#
MOY=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%B)  # full month name (e.g., January)
MOY_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%B)  # full month name (e.g., January)
DOY=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%j)  # Julian day 
#
if [[ "${DOY}" -ne 0 ]]; then
DOY_m1=$((${DOY}-1))
else
DOY_m1=0
fi
#
DOY_END=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${FCST_LENGTH} hours" +%j)  # Julian day 
#
#
# Set the interpolation method to conserve if none is selected
if [ -z "${INTERP_METHOD}" ]; then
   ${ECHO} "No interpolation method selected, defaulting to 'conserve'"
   export INTERP_METHOD="bilinear"
fi
INTERP_METHOD="conserve"
has_init=1
# Set the init/mesh file name and link here:
if [[ -r ${COMINrrfs}/${RUN}${WGF}.${PDY}/${cyc}${MEMDIR}/ic/init.nc ]]; then
   ln -sf ${COMINrrfs}/${RUN}${WGF}.${PDY}/${cyc}${MEMDIR}/ic/init.nc ./${MESH_NAME}.init.nc
else
   echo "WARNING: NO Init File available, cannot reinterpolate if files are missing, did you run the task out of order?"
   has_init=0
fi
#
MPAS_BASEFILE=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/input/grids/domain_latlons/mpas_conus12km_init.nc
#==================================================================================================
#                                 ... Wildfire ...                                             
#==================================================================================================#
if [[ "${EMIS_SECTOR_TO_PROCESS}" == "smoke" ]]; then
#
export REGRID_WRAPPER_LOG_DIR=${DATA}
regrid_wrapper_dir=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/working/ben_interp/regrid-wrapper
PYTHONDIR=${regrid_wrapper_dir}/src
#
SCRIPT=${HOMErrfs}/scripts/regrid_rave_to_mpas.py
#
CONDAENV=/lfs5/BMC/rtwbl/rap-chem/miniconda/envs/regrid-wrapper
#
export PATH=${CONDAENV}/bin:${PATH}
export ESMFMKFILE=${CONDAENV}/lib/esmf.mk
export PYTHONPATH=${PYTHONDIR}:${PYTHONPATH}
#
cd ${REGRID_WRAPPER_LOG_DIR}
mkdir -p ${REGRID_WRAPPER_LOG_DIR}/logs
#
#RAVE_INPUT_DATA=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/input/emissions/fire/rave 
RAVE_INPUT_DATA=/public/data/grids/nesdis/3km_fire_emissions/
TEMPDIR=${DATADIR_CHEM}/emissions/fire/tmp/
rm -f ${TEMPDIR}/*
cp ${RAVE_INPUT_DATA}/* ${TEMPDIR}/
#
RAVE_NAME="RAVE-HrlyEmiss-3km*"
#
RAVE_OUTPUT_DATA=${DATADIR_CHEM}/emissions/fire/processed/rave/
mkdir -p ${RAVE_OUTPUT_DATA}
#
INTERP_WEIGHTS_DIR=${DATADIR_CHEM}/grids/interpolation_weights/
#
dummyRAVE=/mnt/lfs5/BMC/rtwbl/rap-chem/mpas_rt/input/emissions/fire/processed/rave/${MESH_NAME}_dummy_rave.nc
#
# Number of files to process
nfiles=24
smokeFile=smoke.init.nc
ebb_dc=2
dates_needed=()
for i in $(seq 0 $((${nfiles} - 1)) )
do
  if [ "${ebb_dc}" -eq 2 ]; then
      # ${MESH_NAME}-RAVE-${timestr1}00000.nc 
      timestr=`date +%Y%m%d%H -d "$previous_day + $i hours"`
      timestr2=`date +%Y-%m-%d_%H  -d "$current_day + $i hours"`
      intp_fname=${MESH_NAME}-RAVE-${timestr}00000.nc
      
   else
      timestr=`date +%Y%m%d%H -d "$current_day $current_hh + $i hours"`
      intp_fname=${MESH_NAME}-RAVE-${timestr}00_${timestr}59.nc
   fi
   # Link the files to the prep directory if they exists, otherwise, add 
   # the date to the array.
   if  [ -f ${RAVE_OUTPUT_DATA}/${intp_fname} ]; then
      ${LN} -sf ${RAVE_OUTPUT_DATA}/${intp_fname} ${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.${timestr2}.00.00.nc
      echo "${RAVE_OUTPUT_DATA}/${intp_fname} interoplated file available to reuse"
   else
      echo "${RAVE_OUTPUT_DATA}/${intp_fname} interoplated file non available to reuse" 
      dates_needed+=("${timestr}")
   fi
done
#
mpirun -n 24 python -u ${SCRIPT}   \
                   ${TEMPDIR} \
                   ${RAVE_NAME} \
                   ${RAVE_OUTPUT_DATA} \
                   ${INTERP_WEIGHTS_DIR} \
                   ${MESH_NAME} \
                   ${YYYY}${MM}${DD}${HH}00000 \
                   ${dates_needed[@]}
#
mv *.log *.ESMF_LogFile logs || echo "could not move logs"
# 
for ihour in {00..23};  do
#
   timestr1=`date +%Y%m%d%H -d "$previous_day + $ihour hours"`
   timestr2=`date +%Y-%m-%d_%H -d "$current_day + $ihour hours"`
#
   EMISFILE=${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.${timestr2}.00.00.nc
   if [[ -r "${RAVE_OUTPUT_DATA}/${MESH_NAME}-RAVE-${timestr1}.nc" ]]; then
      ln -sf ${RAVE_OUTPUT_DATA}/${MESH_NAME}-RAVE-${timestr1}.nc ${EMISFILE}
      ncrename -v PM25,e_bb_in_smoke_fine -v FRP_MEAN,frp_in -v FRE,fre_in -v SO2,e_bb_in_so2 -v NH3,e_bb_in_nh3 ${EMISFILE}
      ncap2 -O -s 'e_bb_in_smoke_coarse=0.0*e_bb_in_smoke_fine' ${EMISFILE} ${EMISFILE}
      ncap2 -O -s 'frp_in=frp_in*areaCell' -s 'fre_in=fre_in*areaCell' ${EMISFILE} ${EMISFILE}
   else
      cp ${dummyRAVE} ${EMISFILE}
   fi
#
   cp ${MPAS_BASEFILE} ./mpas_basefile.nc
   mv ${EMISFILE} ${EMISFILE}_temp.nc
   ncks -A ${EMISFILE}_temp.nc mpas_basefile.nc
   mv mpas_basefile.nc ${EMISFILE}
   ncks -A -v xtime ${DATA}/${MESH_NAME}.init.nc ${EMISFILE}
   rm -f ${EMISFILE}_temp.nc
#
done
rm -f ${TEMPDIR}/*
# Average for ebb2
ncra ${UMBRELLA_PREP_CHEM_DATA}/smoke.init.retro.*.00.00.nc ${UMBRELLA_PREP_CHEM_DATA}/smoke.init.nc
#
# Calculate previous 24 hour average HWP
#
# Emissions to be calculated inside of model
# 
fi
#
#==================================================================================================
#                                 ... Anthropogenic ...                                             
#==================================================================================================
#
# --- Are we adding anthropogenic sectors?
if [[ "${EMIS_SECTOR_TO_PROCESS}" == "anthro" ]]; then
#
export REGRID_WRAPPER_LOG_DIR=${DATA}
regrid_wrapper_dir=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/working/ben_interp/regrid-wrapper
PYTHONDIR=${regrid_wrapper_dir}/src
#
CONDAENV=/lfs5/BMC/rtwbl/rap-chem/miniconda/envs/regrid-wrapper
#
export PATH=${CONDAENV}/bin:${PATH}
export ESMFMKFILE=${CONDAENV}/lib/esmf.mk
export PYTHONPATH=${PYTHONDIR}:${PYTHONPATH}
if [[ "${ANTHRO_EMISINV}" == "NEMO" ]]; then
SCRIPT=${HOMErrfs}/scripts/regrid_anthro_to_mpas.py 
else
SCRIPT=${HOMErrfs}/scripts/regrid_grapes_to_mpas.py
fi 
# --- Set the file expression and lat/lon dimension names
#
   # --- Do we have hourly emissions regridded to our domain?
   # --- If we already have the hourly emissions, link the first 24 and duplicate for anything beyond 24 hours
   #
   REMAKE_EMIS=0
   dates_needed=()
   for ihour in $(seq 0 $((${FCST_LENGTH} - 1)))
   do
      YYYY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%Y)
      MM_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%m)
      DD_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%d)
      HH_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%H)
      MOY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%B) 
      DOW_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%A)
      if [[ ${DOW_EMIS} -le 5 ]]; then
         DOW_EMIS_STRING=weekdy
      elif [[ ${DOW_EMIS} -eq 6 ]]; then
         DOW_EMIS_STRING=satdy
      else
         DOW_EMIS_STRING=sundy
      fi
      #
      EMISINPUTDIR=${DATADIR_CHEM}/emissions/anthro/raw/${ANTHRO_EMISINV}/${MOY_EMIS}/${DOW_EMIS_STRING}/
      EMISOUTPUTDIR=${DATADIR_CHEM}/emissions/anthro/processed/${ANTHRO_EMISINV}/${MOY_EMIS}/${DOW_EMIS_STRING}/
      #
      EMISFILE=${EMISOUTPUTDIR}/${ANTHRO_EMISINV}_${MESH_NAME}_${HH_EMIS}Z.nc
      #
      ${MKDIR} -p ${EMISOUTPUTDIR}
      #
      LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/anthro.init.${YYYY_EMIS}-${MM_EMIS}-${DD_EMIS}_${HH_EMIS}.00.00.nc
      if [ ! -r ${EMISFILE} ]; then
         ${ECHO} "Can't link anthropogenic input file: ${EMISFILE} and may be missing more. Will attempt to create..."
         REMAKE_EMIS=1
         if [[ ${has_init} -eq 0 ]]; then
            ${ECHO} "Nevermind, no init file, exiting, run ic task"
            exit 1
         fi
         dates_needed+=("${YYYY_EMIS}${MM_EMIS}${DD_EMIS}${HH_EMIS}")
      else
        ${LN} -sf ${EMISFILE} ${UMBRELLA_PREP_CHEM_DATA}/anthro.init.${YYYY_EMIS}-${MM_EMIS}-${DD_EMIS}_${HH_EMIS}.00.00
      fi
   done
   if  [[ ${REMAKE_EMIS} -eq 0 ]] ; then
          ${ECHO} "Successfully linked anthropogenic emissions files"
          exit 0
   else
   #
   # -- Start the regridding process
   #
   # -- Check to see if we already have a weight file, otherwise remake
      REMAKE_WEIGHTS="False"
      REGRID_WEIGHTS=${DATADIR_CHEM}/grids/interpolation_weights/weights_${ANTHRO_EMISINV}-to-${MESH_NAME}_${INTERP_METHOD}.nc
      if [[ -r ${REGRID_WEIGHTS} ]] ; then
         ${ECHO} "Found weight file to interpolate ${ANTHRO_EMISINV} to ${MESH_NAME} at ${REGRID_WEIGHTS}, proceeding with the regrid"
      else
         ${ECHO} "No weight file exists to interpolate ${ANTHRO_EMISINV} to ${MESH_NAME}, will attempt to make one"
         REMAKE_WEIGHTS="True"
      fi
      DSTGRID=${DATA}/${MESH_NAME}.init.nc

   # -- We expect a file with 24 hourly values (00 to 23Z)
   # -- We check the full length of the forecast (i.e., May 31 emissions aren't used for Jun1 if the forecast passes through midnight)
      for ihour in $(seq 0 $((${FCST_LENGTH} - 1)))
      do
         YYYY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%Y)
         MM_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%m)
         DD_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%d)
         HH_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%H)
         MOY_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%B)
         DOW_EMIS=$(date -d "${CDATE:0:8} ${CDATE:8:2} + ${ihour} hours" +%A)
         if [[ ${DOW_EMIS} -le 5 ]]; then
            DOW_EMIS_STRING=weekdy
         elif [[ ${DOW_EMIS} -eq 6 ]]; then 
            DOW_EMIS_STRING=satdy
         else
            DOW_EMIS_STRING=sundy
         fi
         if [[ $ihour -lt 10 ]]; then
            HH_STR="0"${ihour}
         else
            HH_STR=${ihour}
         fi
         #
         if [[ "${ANTHRO_EMISINV}" == "NEMO" ]]; then
            EMISFILE_BASE_RAW=${DATADIR_CHEM}/emissions/anthro/raw/${ANTHRO_EMISINV}/${MOY_EMIS}/${DOW_EMIS_STRING}/${ANTHRO_EMISINV}_${MOY_EMIS}_${DOW_EMIS_STRING}_${HH_STR}.nc
         else
            if [[ $ihour -le 11 ]]; then
            EMISFILE_BASE_RAW=${DATADIR_CHEM}/emissions/anthro/raw/${ANTHRO_EMISINV}/total/2021${MM_EMIS}/${DOW_EMIS_STRING}/GRA2PESv1.0_total_2021${MM_EMIS}_${DOW_EMIS_STRING}_00to11Z.nc
            else
#/lfs5/BMC/rtwbl/rap-chem/mpas_rt/input//emissions/anthro/raw/GRAPES/total/202101/weekdy/
            EMISFILE_BASE_RAW=${DATADIR_CHEM}/emissions/anthro/raw/${ANTHRO_EMISINV}/total/2021${MM_EMIS}/${DOW_EMIS_STRING}/GRA2PESv1.0_total_2021${MM_EMIS}_${DOW_EMIS_STRING}_12to23Z.nc
            fi
         fi
 
         EMISOUTPUTDIR=${DATADIR_CHEM}/emissions/anthro/processed/${ANTHRO_EMISINV}/${MOY_EMIS}/${DOW_EMIS_STRING}/
         ${MKDIR} -p ${EMISOUTPUTDIR}
         EMISFILE=${EMISOUTPUTDIR}/${ANTHRO_EMISINV}_${MESH_NAME}_${HH_EMIS}Z.nc
         #
         if [[ -r ${EMISFILE_BASE_RAW} ]];  then
            ${ECHO} "Found base emission file: ${EMISFILE_BASE_RAW}, will regrid"
         else
            ${ECHO} "No interpolated file and Cannot regrid, no base emission file: ${EMISFILE_BASE_RAW}"
            exit 1
         fi
         #
         if [[ -r ${EMISFILE} ]]; then
            ${ECHO} "${EMISFILE} created in loop, skipping"
            continue
         else
         #
            SRCGRID=${EMISFILE_BASE_RAW}
            DSTGRID=${DATA}/${MESH_NAME}.init.nc
            mpirun -n 24 python -u ${SCRIPT}   \
                       ${DATA} \
                       ${MESH_NAME} \
                       ${REGRID_WEIGHTS} \
                       ${EMISFILE_BASE_RAW} \
                       ${YYYY_EMIS}${MM_EMIS}${DD_EMIS}${HH_EMIS}00000 \
                       ${EMISFILE}
            #
            LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/anthro.init.${YYYY_EMIS}-${MM_EMIS}-${DD_EMIS}_${HH_EMIS}.00.00.nc
            if [[ ! -r ${EMISFILE} ]]; then
               ${ECHO} "ERROR: Did not interpolate ${SRCGRID} to ${DSTGRID}"
               exit 1
            else
               ${ECHO} "Created file #${ihour}/${FCST_LENGTH} at ${EMISFILE}"
               ncks -O -d Time,${ihour},${ihour} ${EMISFILE} ${EMISFILE}
               cp ${MPAS_BASEFILE} ./mpas_basefile.nc
               mv ${EMISFILE} ${EMISFILE}_temp.nc
               ncks -A ${EMISFILE}_temp.nc mpas_basefile.nc
               rm -f ${EMISFILE}_temp.nc
               mv mpas_basefile.nc ${EMISFILE}
               ncks -A -v xtime ${DATA}/${MESH_NAME}.init.nc ${EMISFILE}
               ncap2 -O -s 'e_ant_in_smoke_fine=PEC+POC+PMOTHR' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_smoke_coarse=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_dust_fine=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_dust_coarse=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_unspc_fine=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_unspc_coarse=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_nh4_a_fine=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_so4_a_fine=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_no3_a_fine=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_so2=0.0*POC' ${EMISFILE} ${EMISFILE}
               ncap2 -O -s 'e_ant_in_nh3=0.0*POC' ${EMISFILE} ${EMISFILE}
               ${LN} -sf ${EMISFILE} ${LINKEDEMISFILE}
            fi
          fi
      done
   fi
fi

#==================================================================================================
#                                 ... Biogenic/Pollen ...                                             
#==================================================================================================
# --- Are we adding pollen or other biogenics?
if [[ "${EMIS_SECTOR_TO_PROCESS}" == "pollen" ]]; then
export REGRID_WRAPPER_LOG_DIR=${DATA}
regrid_wrapper_dir=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/working/ben_interp/regrid-wrapper
PYTHONDIR=${regrid_wrapper_dir}/src
#
CONDAENV=/lfs5/BMC/rtwbl/rap-chem/miniconda/envs/regrid-wrapper
#
export PATH=${CONDAENV}/bin:${PATH}
export ESMFMKFILE=${CONDAENV}/lib/esmf.mk
export PYTHONPATH=${PYTHONDIR}:${PYTHONPATH}
SCRIPT=${HOMErrfs}/scripts/regrid_pollen_to_mpas.py
EMISINPUTDIR=${DATADIR_CHEM}/emissions/pollen/raw/${YYYY}
EMISOUTPUTDIR=${DATADIR_CHEM}/emissions/pollen/processed/${YYYY}
${MKDIR} -p ${EMISOUTPUTDIR}
#
# --- Do we have emissions regridded to our domain?
# --- If we already have the emissions, link them..
#
   EMISFILE=${EMISOUTPUTDIR}/pollen_ef_${MESH_NAME}_${YYYY}_${DOY}.nc
   LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/bio.init.nc
   if [ ! -r ${EMISFILE} ]; then
      ${ECHO} "No pollen input file for this specific day: ${EMISFILE}, will look for the file for the whole year"
   else
      ${LN} -sf ${EMISFILE} ${LINKEDEMISFILE}
      ${ECHO} "Linked pollen file ${EMISFILE}, exiting"
      exit 0
   fi
#
# -- Look for the base emission file
#
   EMISFILE_BASE=${EMISINPUTDIR}/pollen_obs_${YYYY}_BELD6_ef_T_${DOY}.nc
   if [[ -r ${EMISFILE_BASE} ]];then
      ${ECHO} "Found base emission file: ${EMISFILE_BASE}"
   else
      ${ECHO} "Cannot regrid, no base emission file: ${EMISFILE_BASE}"
      exit 1
   fi
#
# -- Check to see if we already have a weight file, otherwise remake
#
   REMAKE_WEIGHTS=0
   REGRID_WEIGHTS=${DATADIR_CHEM}/grids/interpolation_weights/weights_beld6_4US3-to-${MESH_NAME}_${INTERP_METHOD}.nc
   if [[ -r ${REGRID_WEIGHTS} ]] ; then
      ${ECHO} "Found weight file to interpolate ${EMISFILE_BASE} to ${MESH_NAME} at ${REGRID_WEIGHTS}, proceeding with the regrid"
   else
      ${ECHO} "No weight file exists to interpolate ${EMISFILE_BASE} to ${MESH_NAME}, will attempt to make one"
      REMAKE_WEIGHTS=1
   fi
   SRCGRID=${EMISFILE_BASE}
   DSTGRID=${DATA}/${MESH_NAME}.init.nc
   mpirun -n 24 python -u ${SCRIPT}   \
                   ${DATA} \
                   ${MESH_NAME} \
                   ${REGRID_WEIGHTS} \
                   ${EMISFILE_BASE} \
                   ${YYYY}${MM}${DD}${HH}00000 \
                   ${EMISFILE}
   if [ ! -r ${EMISFILE} ]; then
      ${ECHO} "Regrid failed, check the logs"
      exit 1
   else
      cp ${MPAS_BASEFILE} ./mpas_basefile.nc
      mv ${EMISFILE} ${EMISFILE}_temp.nc
      ncks -A ${EMISFILE}_temp.nc mpas_basefile.nc
      rm -f ${EMISFILE}_temp.nc
      mv mpas_basefile.nc ${EMISFILE}
      ncks -A -v xtime ${DATA}/${MESH_NAME}.init.nc ${EMISFILE}
      ncap2 -O -s 'e_bio_in_polp_tree=ENL_POLL+DBL_POLL' ${EMISFILE} ${EMISFILE}
      ncrename -v GRA_POLL,e_bio_in_polp_grass -v RAG_POLL,e_bio_in_polp_weed ${EMISFILE}
      ${LN} -sf ${EMISFILE} ${LINKEDEMISFILE}
      ${ECHO} "Linked pollen file ${EMISFILE}, exiting"
      exit 0
   fi
fi # bio/pollen

#==================================================================================================
#                                 ... Dust ...                                             
#==================================================================================================
# --- Are we adding pollen or other biogenics?
if [[ "${EMIS_SECTOR_TO_PROCESS}" == "dust" ]]; then

   REMAKE_WEIGHTS=0
   LINKEDEMISFILE=${UMBRELLA_PREP_CHEM_DATA}/dust.init.nc
   DUST_INPUT_BASE_FILE1=${DATADIR_CHEM}/dust/FENGSHA_2022_NESDIS_inputs_10km_v3.2.nc
   DUST_INPUT_BASE_FILE2=${DATADIR_CHEM}/dust/LAI_GVF_PC_DRAG_CLIMATOLOGY_2024v1.0.nc4
   LATNAME="lat"
   LONNAME="lon"
   FIRST=1
   DUST_INPUT_INTERPOLATED_FILE=${DATADIR_CHEM}/dust/processed/${MESH_NAME}_fengsha_dust_inputs.nc
   if [[ ! -r ${DUST_INPUT_INTERPOLATED_FILE} ]]; then
      ${ECHO} "Interpolated dust file: ${DUST_INPUT_INTERPOLATED_FILE} does not exist, will attempt to create"
      REGRID_WEIGHTS1=${DATADIR_CHEM}/grids/interpolation_weights/fengsha1_dust-to-${MESH_NAME}_${INTERP_METHOD}.nc
      REGRID_WEIGHTS2=${DATADIR_CHEM}/grids/interpolation_weights/fengsha2_dust-to-${MESH_NAME}_${INTERP_METHOD}.nc
      if [[ -r ${REGRID_WEIGHTS1} ]] ; then
         ${ECHO} "Found weight file to interpolate dust to ${MESH_NAME} at ${REGRID_WEIGHTS1}, proceeding with the regrid"
      else
         ${ECHO} "No weight file exists to interpolate dust to ${MESH_NAME}, will attempt to make one"
         REMAKE_WEIGHTS=1
      fi
      SRCREG="True"
      DSTGRID=${DATA}/${MESH_NAME}.init.nc
      DSTREG="True"
      OUTFILE=${DATADIR_CHEM}/dust/processed/${MESH_NAME}_fengsha_dust_inputs.nc
      TMPDIR=${DATADIR_CHEM}/dust/tmp
      mkdir -p ${TMPDIR}
  # !! Different processing for dust...
      source /mnt/lfs5/BMC/rtwbl/rap-chem/miniconda/bin/activate pyremap
      python -u ${HOMErrfs}/scripts/regrid_dust_to_mpas.py \
                ${DUST_INPUT_BASE_FILE1} ${DUST_INPUT_BASE_FILE2} \
                ${SRCREG} ${LATNAME} ${LONNAME} \
                ${DSTGRID} ${DSTREG} \
                ${INTERP_METHOD} ${REGRID_WEIGHTS1} ${REGRID_WEIGHTS2} ${REMAKE_WEIGHTS} \
                ${OUTFILE} ${TMPDIR}
     
      if [[ ! -r ${OUTFILE} ]]; then
         ${ECHO} "ERROR: Did not interpolate ${SRCGRID} to ${DSTGRID}"
         exit 1
      else
         ${ECHO} "Created interpolated file: ${OUTFILE}, linking to ${LINKEDEMISFILE} and exiting"
         ncrename -d time,nMonths ${OUTFILE}
         ncrename -v sep,sep_in -v sandfrac,sandfrac_in -v clayfrac,clayfrac_in -v uthres,uthres_in -v uthres_sg,uthres_sg_in -v feff,feff_m_in -v albedo_drag,albedo_drag_m_in ${OUTFILE}
         ncpdq -O -a nMonths,nCells ${OUTFILE} ${OUTFILE}
         cp ${MPAS_BASEFILE} ./mpas_basefile.nc
         mv ${OUTFILE} ${OUTFILE}_temp.nc
         ncks -A ${OUTFILE}_temp.nc mpas_basefile.nc
         rm -f ${OUTFILE}_temp.nc
         mv mpas_basefile.nc ${OUTFILE}
         ncks -A -v xtime ${DATA}/${MESH_NAME}.init.nc ${OUTFILE}
         ln -sf ${OUTFILE} ${LINKEDEMISFILE}
       fi
   else
         ${LN} -sf ${DUST_INPUT_INTERPOLATED_FILE} ${LINKEDEMISFILE}
         exit 0
   fi

fi # dust



exit 0
