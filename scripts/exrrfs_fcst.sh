#!/usr/bin/env bash
declare -rx PS4='+ $(basename ${BASH_SOURCE[0]:-${FUNCNAME[0]:-"Unknown"}})[${LINENO}]${id}: '
set -x
cpreq=${cpreq:-cpreq}

cd ${DATA}
#
# determine time steps and etc according to the mesh
#
if [[ ${MESH_NAME} == "conus12km" ]]; then
  dt=60
  substeps=2
  disp=12000.0
  radt=30
elif [[ ${MESH_NAME} == "conus3km" ]]; then
  dt=20
  substeps=4
  disp=3000.0
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
fcst_len_hrs_thiscyc=$(${USHrrfs}/find_fcst_length.sh "${fcst_len_hrs_cycles}" "${cyc}" "${fcst_length}")
echo "forecast length for this cycle is ${fcst_len_hrs_thiscyc}"
#
# determine whether to begin new cycles
#
if [[ -r "${UMBRELLA_PREP_IC_DATA}/init.nc" ]]; then
  ln -snf ${UMBRELLA_PREP_IC_DATA}/init.nc mpasin.nc
  start_type='cold'
  do_DAcycling='false'
else
  ln -snf ${UMBRELLA_PREP_IC_DATA}/mpasin.nc mpasin.nc
  start_type='warm'
  do_DAcycling='true'
fi

#
#  link bdy and fix files
#
ln -snf ${UMBRELLA_PREP_LBC_DATA}/lbc*.nc .

ln -snf ${FIXrrfs}/physics/${PHYSICS_SUITE}/* .
ln -snf ${FIXrrfs}/meshes/${MESH_NAME}.ugwp_oro_data.nc ./ugwp_oro_data.nc
zeta_levels=${EXPDIR}/config/ZETA_LEVELS.txt
nlevel=$(wc -l < ${zeta_levels})
ln -snf ${FIXrrfs}/meshes/${MESH_NAME}.invariant.nc_L${nlevel} ./invariant.nc
mkdir -p graphinfo stream_list
ln -snf ${FIXrrfs}/graphinfo/* graphinfo/
ln -snf ${FIXrrfs}/stream_list/${PHYSICS_SUITE}/* stream_list/

#
# Link Chemistry Files
#
# Biogenic/Pollen
if [[ -r "${UMBRELLA_PREP_CHEM_DATA}/bio.init.nc" ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/bio.init.nc bio.init.nc
fi
# Dust
if [[ -r "${UMBRELLA_PREP_CHEM_DATA}/dust.init.nc" ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/dust.init.nc dust.init.nc
fi
# Anthropogenic
nanthrofiles=`ls ${UMBRELLA_PREP_CHEM_DATA}/anthro.init* | wc -l`
if [[ ${nanthrofiles} -gt 0 ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/anthro.init* ./
fi
# Smoke/Wildfire
nfirefiles=`ls ${UMBRELLA_PREP_CHEM_DATA}/smoke.init.* | wc -l`
if [[ ${nfirefiles} -gt 0 ]]; then
   ln -snf ${UMBRELLA_PREP_CHEM_DATA}/smoke.init* ./
fi
module load nco
yesterday_name=$(date -d "${CDATE:0:8} ${CDATE:8:2} - 24 hours" +%Y%m%d%H)
today_name=$(date -d "${CDATE:0:8} ${CDATE:8:2}" +%Y-%m-%d) # history.2025-03-17_00.00.00.nc
yesterday_chem_name=/lfs5/BMC/rtwbl/rap-chem/mpas_rt/cycledir/stmp/${yesterday_name}/rrfs_fcst_00_v2.0.9/det/fcst_00/mpasout.${today_name}_00.00.00.nc
if [[ -r ${yesterday_chem_name} ]]; then
ncks -A -v unspc_fine,unspc_coarse,smoke_fine,smoke_coarse,dust_fine,dust_coarse,polp_tree,polp_grass,polp_weed,pols_all,ssalt_fine,ssalt_coarse ${yesterday_chem_name} mpasin.nc
else
ncap2 -O -s 'smoke_fine=1.e-12*qv' -s 'smoke_coarse=1.e-12*qv' -s 'dust_fine=1.e-12*qv' -s 'dust_coarse=1.e-12*qv' -s 'dust_fine=1.e-12*qv' -s 'dust_coarse=1.e-12*qv' -s 'unspc_fine=1.e-12*qv' -s 'unspc_coarse=1.e-12*qv' -s 'ssalt_fine=1.e-12*qv' -s 'ssalt_coarse=1.e-12*qv' -s 'polp_tree=1.e-12*qv' -s 'polp_grass=1.e-12*qv' -s 'polp_weed=1.e-12*qv' -s 'pols_all=1.e-12*qv' mpasin.nc mpasin.nc
fi

for file in lbc*
do
ncap2 -O -s 'lbc_smoke_fine=1.e-12*lbc_qv' -s 'lbc_smoke_coarse=1.e-12*lbc_qv' -s 'lbc_dust_fine=1.e-12*lbc_qv' -s 'lbc_dust_coarse=1.e-12*lbc_qv' -s 'lbc_unspc_fine=1.e-12*lbc_qv' -s 'lbc_unspc_coarse=1.e-12*lbc_qv' -s 'lbc_ssalt_fine=1.e-12*lbc_qv' -s 'lbc_ssalt_coarse=1.e-12*lbc_qv' -s 'lbc_polp_tree=1.e-12*lbc_qv' -s 'lbc_polp_grass=1.e-12*lbc_qv' -s 'lbc_polp_weed=1.e-12*lbc_qv' -s 'lbc_pols_all=1.e-12*lbc_qv' ${file} ${file}
done
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
file_content=$(< ${PARMrrfs}/${physics_suite}/namelist.atmosphere) # read in all content
eval "echo \"${file_content}\"" > namelist.atmosphere

# generate the streams file on the fly using sed as this file contains "filename_template='lbc.$Y-$M-$D_$h.$m.$s.nc'"
lbc_interval=${LBC_INTERVAL:-3}
restart_interval=${RESTART_INTERVAL:-99}
history_interval=${HISTORY_INTERVAL:-1}
diag_interval=${HISTORY_INTERVAL:-1}
sed -e "s/@restart_interval@/${restart_interval}/" -e "s/@history_interval@/${history_interval}/" \
    -e "s/@diag_interval@/${diag_interval}/" -e "s/@lbc_interval@/${lbc_interval}/" \
    ${PARMrrfs}/streams.atmosphere  > streams.atmosphere
#
# prelink the forecast output files to umbrella
history_all=$(seq 0 $((10#${history_interval})) $((10#${fcst_len_hrs_thiscyc} )) )
for fhr in ${history_all}; do
  CDATEp=$( $NDATE ${fhr} ${CDATE} )
  timestr=$(date -d "${CDATEp:0:8} ${CDATEp:8:2}" +%Y-%m-%d_%H.%M.%S)
  if [[ "${DO_SPINUP:-FALSE}" != "TRUE" ]];  then
    ln -snf ${DATA}/history.${timestr}.nc ${UMBRELLA_FCST_DATA}
    ln -snf ${DATA}/diag.${timestr}.nc ${UMBRELLA_FCST_DATA}
    ln -snf ${DATA}/mpasout.${timestr}.nc ${UMBRELLA_FCST_DATA}
  fi
done

# run the MPAS model
ulimit -s unlimited
ulimit -v unlimited
ulimit -a
source prep_step
${cpreq} ${EXECrrfs}/atmosphere_model.x .
${MPI_RUN_CMD} ./atmosphere_model.x 
#
# check the status
#
num_err_log=$(ls ./log.atmosphere*.err 2>/dev/null | wc -l)
if (( ${num_err_log} > 0 )) ; then
  echo "FATAL ERROR: MPAS model run failed"
  err_exit
else
  # spinup cycles copy mpasout to com/ directly, don't need the save_fcst task
  if [[ "${DO_SPINUP:-FALSE}" == "TRUE" ]];  then
    CDATEp=$( $NDATE 1 ${CDATE} )
    timestr=$(date -d "${CDATEp:0:8} ${CDATEp:8:2}" +%Y-%m-%d_%H.%M.%S)
    ${cpreq} ${DATA}/mpasout.${timestr}.nc ${COMOUT}/fcst_spinup/.
  fi
  exit 0
fi
