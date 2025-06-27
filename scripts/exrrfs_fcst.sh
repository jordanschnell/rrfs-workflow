#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2153,SC2154,SC2034
declare -rx PS4='+ $(basename ${BASH_SOURCE[0]:-${FUNCNAME[0]:-"Unknown"}})[${LINENO}]: '
set -x
cpreq=${cpreq:-cpreq}
prefix=${EXTRN_MDL_SOURCE%_NCO} # remove the trailing '_NCO' if any
cd "${DATA}" || exit 1
#
# determine time steps and etc according to the mesh
#
if [[ ${MESH_NAME} == "conus12km" ]]; then
  dt=60
  substeps=2
  radt=30
elif [[ ${MESH_NAME} == "conus3km" ]]; then
  dt=20
  substeps=4
  radt=15
else
  echo "Unknown MESH_NAME, exit!"
  err_exit
fi
#
# find forecst length for this cycle
#
fcst_length=${FCST_LENGTH:-1}
fcst_len_hrs_cycles=${FCST_LEN_HRS_CYCLES:-"01 01"}
fcst_len_hrs_thiscyc=$("${USHrrfs}/find_fcst_length.sh" "${fcst_len_hrs_cycles}" "${cyc}" "${fcst_length}")
echo "forecast length for this cycle is ${fcst_len_hrs_thiscyc}"
#

# Link Chemistry Files
#
module load nco
# Biogenic/Pollen
if [[ -r "${UMBRELLA_PREP_CHEM_DATA}/bio.init.nc" ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/bio.init.nc bio.init.nc
   ncks -A -v xtime mpasin.nc bio.init.nc
fi
# Dust
if [[ -r "${UMBRELLA_PREP_CHEM_DATA}/dust.init.nc" ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/dust.init.nc dust.init.nc
   ncks -A -v xtime mpasin.nc dust.init.nc
fi
# Anthropogenic
nanthrofiles=`ls ${UMBRELLA_PREP_CHEM_DATA}/anthro.init* | wc -l`
if [[ ${nanthrofiles} -gt 0 ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/anthro.init* ./
   for file in anthro.init*
   do
      ncks -A -v xtime mpasin.nc ${file}
   done
fi
# Smoke/Wildfire
nfirefiles=`ls ${UMBRELLA_PREP_CHEM_DATA}/smoke.init.* | wc -l`
if [[ ${nfirefiles} -gt 0 ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/smoke.init* ./
   for file in smoke.init*
   do
      ncks -A -v xtime mpasin.nc ${file}
   done
   
fi

## 
# generate the namelist on the fly
# do_restart already defined in the above
start_time=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%Y-%m-%d_%H:%M:%S) 
run_duration=${fcst_len_hrs_thiscyc:-1}:00:00
physics_suite=${PHYSICS_SUITE:-'mesoscale_reference'}
jedi_da="true" #true

if [[ "${MESH_NAME}" == "conus12km" ]]; then
  pio_num_iotasks=1
  pio_stride=40
elif [[ "${MESH_NAME}" == "conus3km" ]]; then
  pio_num_iotasks=40
  pio_stride=20
fi

# generate the streams file on the fly using sed as this file contains "filename_template='lbc.$Y-$M-$D_$h.$m.$s.nc'"
lbc_interval=${LBC_INTERVAL:-3}
restart_interval=${RESTART_INTERVAL:-99}
history_interval=${HISTORY_INTERVAL:-1}
diag_interval=${HISTORY_INTERVAL:-1}
#
# prelink the forecast output files to umbrella
history_all=$(seq 0 $((10#${history_interval})) $((10#${fcst_len_hrs_thiscyc} )) )
# run the MPAS model
source prep_step
${cpreq} "${EXECrrfs}"/atmosphere_model.x .
${MPI_RUN_CMD} ./atmosphere_model.x 
export err=$?
err_chk
#
# double check status as sometimes atmosphere_model.x exit with 0 but there are still errors (log.atmosphere*err)
#
num_err_log=$(find ./log.atmosphere*.err 2>/dev/null | wc -l)
if (( "${num_err_log}" > 0 )) ; then
  echo "FATAL ERROR: MPAS model run failed"
  err_exit
else
  # spinup cycles copy mpasout and log file to com/ directly, don't need the save_fcst task
  if [[ "${DO_SPINUP:-FALSE}" == "TRUE" ]];  then
    CDATEp=$( ${NDATE} 1 "${CDATE}" )
    timestr=$(date -d "${CDATEp:0:8} ${CDATEp:8:2}" +%Y-%m-%d_%H.%M.%S)
    ${cpreq} "${DATA}/mpasout.${timestr}.nc" "${COMOUT}/fcst_spinup/${WGF}${MEMDIR}"
    ${cpreq} "${DATA}/log.atmosphere.0000.out" "${COMOUT}/fcst_spinup/${WGF}${MEMDIR}"
  fi
  exit 0
fi
