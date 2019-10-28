PROGRAM main

  ! JAN 2017
  ! VAR model for rollingstone -- observable ugap
  ! QUARTERLY MODEL WITH CONSTANT PARAMETERS 
  ! handles also missing data
  ! NEW: predictive density, including 4-quarter inflation

  ! added a flag to switch on/off pdf computations

  USE embox, only: hrulefill, savemat, savevec, storeestimatesOMP, storeestimates, lofT, int2str, timestampstr, es30d16, logtwopi
  USE blaspack, only: eye, sandwich, vech
  USE gibbsbox, only: GelmanTest1, simpriormaxroot, igammadraw, iwishcholdraw
  use densitybox, only : crps, logGaussianScore, logGaussianScoreMV

  USE vslbox
  USE timerbox
  USE omp_lib

  IMPLICIT NONE

  ! ----------------------------------------------------------------------------------

  LOGICAL, PARAMETER :: doTimestamp = .false.

  INTEGER :: Nyield, Ny,  Nbar, Ngap, Nshock
  INTEGER :: Ngapvcv

  INTEGER :: gapOrderKey = 1234
  ! gapOrderKey is a 4-digit code that specifies the order of variables within the gap block:
  ! - the first digit (from the left) specifies the position of inflation
  ! - the 2nd digit is for ugap
  ! - 3rd digit is the policy rate gap
  ! - 4th digit is the yield block
  ! - the implementation is handled via a select case statement in thissampler, missing cases can simply be added there

  INTEGER :: p
  INTEGER, PARAMETER :: longrateHorizon = 4 * 5 ! in quarters
  LOGICAL :: ZLBrejection = .false., doPDF = .false., doPInoise = .false.
  LOGICAL :: doZLBasZeroes = .false.

  ! forecasting parameters
  integer :: NNyy 
  INTEGER, PARAMETER :: Nforecastdraws = 50
  integer :: NNxx

  ! horizons are consecutive sequence up to maxhorizon
  integer, parameter :: maxhorizons = 8
  integer, dimension(maxhorizons)  :: horizons

  ! forecast obs
  ! double precision, dimension(NNyy,maxhorizons) :: ypred
  ! logical, dimension(NNyy,maxhorizons) :: yNaNpred
  double precision, allocatable, dimension(:,:) :: ypred
  logical, allocatable, dimension(:,:) :: yNaNpred

  ! forecast results
  ! double precision, allocatable, dimension(:,:,:,:) :: DRAWypdf, DRAWyforecast, DRAWymedian, DRAWyprobLB, DRAWycondvar
  double precision, allocatable, dimension(:,:,:,:,:) :: DRAWy

  INTEGER :: Tdata
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: yhatmean, yhatmedian ! , yavgcondvar, yvarcondexp, ycondvar
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: crpsScore, logScore
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: logScoreMV

  INTEGER :: Nx, Nf, Nstates

  INTEGER :: Nsim, Burnin, Nstreams
  INTEGER :: T,h,i,j,k,n,status,Ndraws
  INTEGER :: T0 = 0 ! jump off when reading in data
  ! LOGICAL :: OK
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:,:,:) :: DRAWstates
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:,:) :: DRAWavgtermpremia
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:,:) :: DRAWf, DRAWrbarvar, DRAWmaxlambda
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:,:) :: DRAWgapvcvchol, DRAWpibarvar, DRAWpinoisevar

  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: Ef0

  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: sqrtVf0
  DOUBLE PRECISION :: lambda1Vf, lambda2Vf

  INTEGER :: rbarvarDof
  DOUBLE PRECISION :: rbarvarT

  INTEGER :: pibarvarDof, pinoisevarDof
  DOUBLE PRECISION :: pibarvarT, pinoisevarT

  INTEGER :: gapvcvDof
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: gapvcvT, gapvcvchol ! gapvcvchol is used for storing prior draws


  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: GELMANstates
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: theta
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:)   :: theta1

  ! DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:,:) :: thetaDraws
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: GELMANf
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: GELMANgapvcvchol
  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: GELMANrbarvar, GELMANpibarvar, GELMANpinoisevar

  ! DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:) :: thetaprob

  INTEGER :: ndxRealrate, ndxPIbar, ndxRbar, ndxLONGRbar, ndxPIgap, ndxPInoise, ndxUgap, ndxINTgap, ndxLONGINTgap, ndxSHADOWRATE

  INTEGER :: yndxPolicyRate = 3

  DOUBLE PRECISION, ALLOCATABLE, DIMENSION(:,:) :: y
  LOGICAL, ALLOCATABLE, DIMENSION(:,:) :: yNaN, zlb

  TYPE(progresstimer) :: timer
  CHARACTER (LEN=200) :: filename, datafile, nandatafile, filext, datalabel

  ! VSL Random Stuff
  ! type (vsl_stream_state), allocatable, dimension(:) :: VSLstreams
  type (vsl_stream_state) :: VSLdefaultstream, VSLstream
  integer :: seed
  ! integer :: brng
  integer :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0

  ! OPEN MP
  INTEGER :: NTHREADS, TID

  ! Lower Bound
  DOUBLE PRECISION, PARAMETER :: ELBound = 0.25d0

  ! ----------------------------------------------------------------------------------
  ! MODEL PARAMETERS
  ! ----------------------------------------------------------------------------------
  ! runtime parameters :start:
  ! first: set default values

  Nyield = 3  ! just a default, can be overriden by command line arguments
  p      = 2  ! just a default, can be overriden by command line arguments

  ! TOC

  Nsim    = 2 * (10 ** 4)
  Burnin  = (10 ** 5)

  Nsim    = 10 ** 4
  Burnin  = 10 ** 4

  ! Nsim    = 10 ** 4
  ! Burnin  = 10 ** 5


  Nsim    = (10 ** 3)           
  Burnin  = (10 ** 3)

  ! ! QUICK
  ! Nsim    = (10 ** 2)
  ! Burnin  = (10 ** 2)

  ! ----------------------------------------------------------------------------------
  ! INIT
  ! ----------------------------------------------------------------------------------

  ! INIT OMP
  NTHREADS = 1
  !$OMP PARALLEL SHARED(NTHREADS)
  !$ NTHREADS = OMP_GET_NUM_THREADS()
  !$OMP END PARALLEL
  Nstreams = max(NTHREADS, 4)
  print *, "Number of Threads:", NTHREADS
  print *, "Number of Streams:", Nstreams


  ! VSL
  call hrulefill
  write (*,*) 'Allocating VSLstreams ...'

  seed    = 0
  errcode = vslnewstream(VSLdefaultstream, vsl_brng_mt2203, seed)  
  WRITE(*,*) "... default VSLstream ", VSLdefaultstream
  write (*,*) '... VSLstreams done.'
  call hrulefill

  ! define forecast horizons
  forall (k=1:maxhorizons) horizons(k) = k

  ! read data
  datalabel   = 'spectreTB3MSGS020510Headline2018Q4' ! just a placeholder
  
  ! datalabel   = 'spectreGS5Headline2016Q4';
  ! datafile    = trim(datalabel) // '.yData.txt'
  ! Tdata = loft(datafile) 
  ! IF (Tdata < 10) THEN
  !    print *, 'Less than 10 observations in input file!', datafile
  !    STOP 1
  ! END IF

  ! T0 = 120 ! T0 = 120 skips data prior to 1990Q1
  T = Tdata - T0! default
  call getarguments(ZLBrejection, doPDF, doPInoise, doZLBasZeroes, T, T0, gapOrderKey, datalabel, Nyield, p, Nsim, burnin, Nstreams)

  ! set parameters that depend on Nyield
  Ny = 3 + Nyield
  Nbar = 1 + 1 + Nyield
  Ngap = Ny
  Ngapvcv = Ngap * (Ngap + 1) / 2
  Nshock = 2 + Ngap + 1 ! two trends, every gap plus pinoise
  NNyy = Ny + 2 ! adding 4q-MA of inflation and the shadowrate
  Nx        = Nbar + (Ngap * p) + 1                      ! Nbar and Ngaps (with lags), pinoise
  Nf        = Ngap * (Ngap * p)


  ! runtime parameters :end: 

  Nstates   = 8 + 2 * Nyield ! see list of ndxXXX below

  ndxRealrate     = 1
  ndxPIbar        = 2
  ndxRbar         = 3
  ndxLONGRbar     = 4
  ndxPIgap        = ndxLONGRbar  + Nyield
  ndxUgap         = ndxPIgap + 1
  ndxINTgap       = ndxUgap + 1
  ndxLONGINTgap   = ndxINTgap + 1
  ndxPInoise      = ndxLONGINTgap + Nyield
  ndxSHADOWRATE   = ndxPInoise + 1


  if (ndxSHADOWRATE .ne. Nstates) then
     print *, 'state indices are off'
     stop 1
  end if

  if (doZLBasZeroes) then
     ! doShadowObsGap = .false.
     ZLBrejection   = .false.
  end if

  datafile    = trim(datalabel) // '.yData.txt'
  nandatafile = trim(datalabel) // '.yNaN.txt'

  print *, datalabel
  print *, datafile
  Tdata = loft(datafile) 
  IF (Tdata < T) THEN
     print *, 'Data file has less than T obs', datafile, T, Tdata
     STOP 1
  END IF


  ! read in data 
  ALLOCATE (yNaN(Ny,T), zlb(Ny,T), y(Ny,T), STAT=status)
  IF (status /= 0) THEN
     WRITE (*,*) 'Allocation problem (Y)'
  END IF

  ! print *, 'trying to read', T, 'obs from', datafile
  CALL readdata(y,datafile,Ny,T,T0)
  CALL readnandata(yNaN,nandatafile,Ny,T,T0)

  if (doZLBasZeroes .eqv. .true.) then
     yNaN(yndxPolicyRate,:) = .false.
  end if

  ! call savemat(y, 'y.debug')
  ! call savemat(dble(yNaN), 'yNaN.debug')

  ! define a separate ZLB index to distinguish rates at ZLB from actually missing observations
  zlb = .false.
  ! for now: zlb matters only for poliyc rate not longer-term yields
  ! NOTE: key assumption is that missing obs for policy rate are solely due to ZLB!!
  zlb(yndxPolicyRate,:) = yNaN(yndxPolicyRate,:) 

  ALLOCATE (ypred(NNyy,maxhorizons), ynanpred(NNyy,maxhorizons), STAT=status)
  IF (status /= 0) THEN
     WRITE (*,*) 'Allocation problem (Y)'
  END IF
  ypred    = readpreddata(datafile,Ny,NNyy,maxhorizons,Tdata,T+T0)
  yNaNpred = readprednandata(nandatafile,Ny,NNyy,maxhorizons,Tdata,T+T0)

  ! fix ELB predictions for the policy rate:
  ! they are read in as missing data, but should be set to the ELB
  ! assumptions:
  ! -- there are no missing data for the policy rate in sample
  ! -- ELB obs are encoded as exact zeros
  where (ypred(yndxPolicyRate,:) == 0.0d0)
     ypred(yndxPolicyRate,:)     = ELBound
     yNaNpred(yndxPolicyRate,:)  = .false.
  end where
  ! same for the shadowrate
  where (ypred(NNyy,:) == 0.0d0)
     ypred(NNyy,:)     = ELBound
     yNaNpred(NNyy,:)  = .false.
  end where
  ! call savemat(ypred, 'ypred.debug')
  ! call savemat(dble(ynanpred), 'nanypred.debug')
  ! stop 11

  ! setup number of states in extended state vector (used for forecasting; append 3 inflation lags)
  NNxx          = Nx + 3

  filext = '.SPECTREVARCONST.' // trim(datalabel) // '.VARlags' // trim(int2str(p)) // '.order' // trim(int2str(gapOrderKey)) // '.T' // trim(int2str(T)) // '.Tjumpoff' // trim(int2str(T0)) // '.dat'
  if (ZLBrejection) then
     filext = '.zlb' // filext
  end if
  if (.not. doPInoise) then
     filext = '.nopinoise' // filext
  end if
  if (doZLBasZeroes) then
     filext = '.zlbaszeroes' // filext
  end if
  if (doTimeStamp) filext = '.' // timestampstr() //  filext


  ! Model parameters and priors
  ALLOCATE (Ef0(Nf), sqrtVf0(Nf,Nf))



  ! ----------------------------------------------------------
  ! Sigma
  ! ----------------------------------------------------------
  rbarvarDof  = 3
  rbarvarT    = (0.2d0 ** 2) * dble(rbarvarDof - 2)  ! corresponds to estimated variance of LW
  ! Del Negro et al value, but with looser dof
  ! rbarvarT    = (1.0d0 / 400.0d0) * dble(rbarvarDof - 2)  
  
  pibarvarDof  = 3 
  pibarvarT    = (0.2d0 ** 2) * dble(pibarvarDof - 2)
  ! Del Negro et al value, but with looser dof
  ! pibarvarT    = (4.0d0 / 400.0d0) * dble(pibarvarDof - 2) 

  ! some value, model variant not used anyhow
  pinoisevarDof  = 3 
  pinoisevarT    = (.1d0 ** 2) * dble(pinoisevarDof - 2) 

  ! TODO CALIBRATE
  ALLOCATE (gapvcvT(Ngap,Ngap))
  gapvcvDof = Ngap + 2
  call eye(gapvcvT, dble(gapvcvDof - 2))  
  ! gapvcvDof = 0
  ! gapvcvT = 0.0d0

  ! cycle VAR coefficients
  Ef0  = 0.0d0

  lambda1Vf = 0.3d0
  lambda2Vf = 1.0d0
  lambda1Vf = 0.5d0
  lambda2Vf = 0.2d0
  call minnesotaVCVsqrt(sqrtVf0, Ny, p, lambda1Vf, lambda2Vf)


  ! REPORT PARAMETERS TO SCREEN
  CALL HRULEFILL
  print *, 'data     = ' // trim(datalabel)
  print *, 'T        = ', T
  print *, 'T0       = ', T0
  ! print *, 'longrateHorizon= ', longrateHorizon
  print *, 'Nsim     = ', Nsim
  print *, 'Burnin   = ', Burnin
  print *, 'Nstreams = ', Nstreams
  print *, 'p        = ', p
  print *, 'gapOrderKey= ', gapOrderKey
  print *, 'ELBound  = ', ELBound

  if (doPInoise) then
     print *, 'with PI noise'
  else
     print *, 'without PI noise'
  end if
  if (ZLBrejection) print *, 'with ZLB rejection'
  ! if (doLongRateTruncation) print *, 'with LongRateTruncation'
  if (doPDF) print *, 'with PDF computation'
  if (doZLBasZeroes) print *, 'treating policy rate at ELB as data'
  print *, 'A few priors:'
  print *, 'rbarvar        = ', rbarvarT / dble(rbarvarDof - 2), ' w/dof: ', rbarvarDof
  print *, 'pibarvar       = ', pibarvarT / dble(pibarvarDof - 2), ' w/dof: ', pibarvarDof
  CALL HRULEFILL

  ! ----------------------------------------------------------------------------
  ! GENERATE AND STORE DRAWS FROM PRIORS
  ! ----------------------------------------------------------------------------
  Ndraws = max(10000, Nsim * Nstreams)

  ! sigma
  ALLOCATE (theta(1,Ndraws))
  DO k = 1, Ndraws
     call igammaDraw(theta(1,k), rbarvarT, rbarvarDof, VSLdefaultstream)
  END DO
  filename  = 'rbarvar' // '.prior' // filext
  call savemat(transpose(theta), filename)
  WRITE (*,*) 'STORED PRIOR RBARVAR'
  DEALLOCATE (theta)

  ALLOCATE (theta(1,Ndraws))
  DO k = 1, Ndraws
     call igammaDraw(theta(1,k), pibarvarT, pibarvarDof, VSLdefaultstream)
  END DO
  filename  = 'pibarvar' // '.prior' // filext
  call savemat(transpose(theta), filename)
  WRITE (*,*) 'STORED PRIOR PIBARVAR'
  DEALLOCATE (theta)

  if (doPInoise) then
     ALLOCATE (theta(1,Ndraws))
     DO k = 1, Ndraws
        call igammaDraw(theta(1,k), pinoisevarT, pinoisevarDof, VSLdefaultstream)
     END DO
     filename  = 'pinoisevar' // '.prior' // filext
     call savemat(transpose(theta), filename)
     WRITE (*,*) 'STORED PRIOR PINOISEVAR'
     DEALLOCATE (theta)
  end if

  if (gapvcvDof > 0) then
     ALLOCATE (gapvcvchol(Ngap,Ngap))
     ALLOCATE (theta(Ngapvcv,Ndraws))
     DO k = 1, Ndraws
        ! call iwishDraw(gapvcv, gapvcvT, gapvcvDof, Ngap, VSLdefaultstream)
        call iwishcholDraw(gapvcvchol, gapvcvT, gapvcvdof, Ngap, VSLdefaultstream)
        ! note: upper LEFT choleski factor, same format will beused for posteriors
        call vech(theta(:,k), gapvcvchol)
     END DO
     filename  = 'gapvcvchol' // '.prior' // filext
     call savemat(transpose(theta), filename)
     WRITE (*,*) 'STORED PRIOR GAPVCVCHOL'
     DEALLOCATE (theta)
     DEALLOCATE (gapvcvchol)
  end if

  ! maxlambda
  ALLOCATE (theta(Ndraws,1))
  call simPriorMaxroot(theta(:,1), Ndraws, Ef0, sqrtVf0, Ny, p, VSLdefaultstream)
  filename  = 'maxlambda' // '.prior' // filext
  call savevec(theta(:,1), filename)
  WRITE (*,*) 'STORED PRIOR MAXLAMBDA'
  DEALLOCATE (theta)



  ! ----------------------------------------------------------------------------
  ! DONE: SIMULATING PRIORS
  ! ----------------------------------------------------------------------------



  ! allocate memory for draws
  ALLOCATE (DRAWmaxlambda(1,Nsim,Nstreams), DRAWf(Nf,Nsim,Nstreams),  DRAWrbarvar(1,Nsim,Nstreams), DRAWstates(Nstates,0:T,Nsim,Nstreams), STAT=status)
  ALLOCATE (DRAWpibarvar(1,Nsim,Nstreams), DRAWpinoisevar(1,Nsim,Nstreams), STAT=status)
  ALLOCATE (DRAWgapvcvchol(Ngapvcv,Nsim,Nstreams), STAT=status)



  ALLOCATE (DRAWavgtermpremia(Nyield,Nsim,Nstreams), STAT=status)
  ! IF (status /= 0) THEN
  !    WRITE (*,*) 'Allocation problem (draws)'
  ! END IF
  allocate(DRAWy(NNyy,maxhorizons,Nforecastdraws,Nsim,Nstreams))


  call hrulefill
  WRITE(*,*) 'STARTING SWEEPS'
  call hrulefill

  !$OMP PARALLEL DO SHARED(DRAWy,DRAWavgtermpremia,DRAWstates,DRAWf,DRAWgapvcvchol,DRAWrbarvar,DRAWpibarvar,DRAWpinoisevar,DRAWmaxlambda), FIRSTPRIVATE(ZLBrejection,doPDF,doPInoise, gapOrderKey, Nstreams, Nsim,Burnin,T,y,yNaN,zlb,Nstates,Nx, Nf, Ef0, sqrtVf0, Ngapvcv, gapvcvT, gapvcvDof, rbarvarT, rbarvarDof, pibarvarT, pibarvarDof, pinoisevarT, pinoisevarDof, NNxx), PRIVATE(VSLstream,TID,errcode,timer) SHARED(Nyield,Ny,Nbar,Ngap,Nshock,p,NNyy) DEFAULT(NONE) SCHEDULE(STATIC)

  DO j=1,Nstreams

     TID = 0
     !$ TID = OMP_GET_THREAD_NUM()

     errcode = vslnewstream(VSLstream, vsl_brng_mt2203 + 1 + j, 0)  
     if (errcode /= 0) then
        print *,'VSL new stream failed'
        stop 1
     end if


     WRITE(*,'(a16, i2, a5, i2, a8, i20, i20)') ' LAUNCHING SWEEP ', j, ' TID ', TID, ' Stream ', VSLstream%descriptor1, VSLstream%descriptor2
     ! print *,' TID ', TID,  VSLstream

     CALL initprogressbar(timer, 15.0d0, j)
     call thissampler(ZLBrejection, ELBound, doPDF, doPInoise, gapOrderKey, T, Ny, Nyield, y, yNaN, zlb, NNyy, NNxx, DRAWy(:,:,:,:,j), Nforecastdraws, maxhorizons, DRAWavgtermpremia(:,:,j), DRAWstates(:,:,:,j), Nstates, Nx, Nshock, Nbar, Ngap, p, DRAWf(:,:,j), Nf, Ef0, sqrtVf0, DRAWmaxlambda(:,:,j), DRAWgapvcvchol(:,:,j), Ngapvcv, gapvcvT, gapvcvDof, DRAWrbarvar(:,:,j), rbarvarT, rbarvarDof, DRAWpibarvar(:,:,j), pibarvarT, pibarvarDof, DRAWpinoisevar(:,:,j), pinoisevarT, pinoisevarDof,  Nsim, Burnin, VSLstream, timer)

     ! WRITE(*,*) 'STREAM', j, 'IS DONE.', ' (TID: ', TID, ')'
     errcode = vsldeletestream(VSLstream)     

  END DO
  !$OMP END PARALLEL DO 


  CALL HRULEFILL
  WRITE (*,*) 'ALL STREAMS ARE DONE!'
  CALL HRULEFILL

  ! WRITE SETTINGS
  CALL HRULEFILL
  filename = 'settings' // trim(adjustl(filext))
  OPEN (UNIT=4, FILE=filename, STATUS='REPLACE', ACTION='WRITE')
  WRITE(4,'(a20,a20)') 'TIME: ', timestampstr()
  WRITE(4,'(a20,a20)') 'Data: ', datalabel
  ! WRITE(4,'(a20,I20)') 'longrateHorizon: ', longrateHorizon
  WRITE(4,'(a60)') repeat('-',60)
  WRITE(4,'(a20,I20)') 'Sims: ', Nsim
  WRITE(4,'(a20,I20)') 'Burnin: ', Burnin
  WRITE(4,'(a20,I20)') 'Streams: ', Nstreams
  WRITE(4,'(a20,I20)') 'p: ', p
  WRITE(4,'(a20,F4.2)') 'ELBound: ', ELBound
  WRITE(4,'(a60)') repeat('-',60)

  WRITE(4,'(a10)') 'PRIORS:'
  WRITE(4,'(a20,F6.4, a6, I4)') 'rbarvar = ', rbarvarT / dble(rbarvarDof - 2), ' w/dof: ', rbarvarDof
  WRITE(4,'(a20,F6.4, a6, I4)') 'pibarvar = ', pibarvarT / dble(rbarvarDof - 2), ' w/dof: ', pibarvarDof

  WRITE(4,'(a60)') repeat('-',60)
  CLOSE(UNIT=4)
  CALL HRULEFILL




  ! ----------------------------------------------------------------------------
  ! STORE
  ! ----------------------------------------------------------------------------

  CALL HRULEFILL
  WRITE (*,*) 'STARTING W/STORAGE'
  CALL HRULEFILL

  ! STORE ESTIMATES
  ! Note: manual reshape avoids segmentation faults
  Ndraws = Nsim * Nstreams

  filename = 'YDATA' // filext
  call savemat(y, filename)

  filename = 'YNAN' // filext
  call savemat(dble(ynan), filename)

  ALLOCATE (theta(T,Ndraws))

  ! filename  = 'INFLATIONTREND.DRAWS' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxRealrate,1:T,k,j)
  ! call savemat(theta, filename)
  filename  = 'REALRATE' // filext
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED REALRATE'

  ! filename  = 'INFLATIONTREND.DRAWS' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxPIbar,1:T,k,j)
  ! call savemat(theta, filename)
  filename  = 'INFLATIONTREND' // filext
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED INFLATIONTREND'


  ! filename  = 'REALRATETREND.DRAWS' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxRbar,1:T,k,j)
  ! call savemat(theta, filename)
  filename  = 'REALRATETREND' // filext
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED REALRATETREND'

  do i = 1,Nyield
     ! filename  = 'LONGREALRATETREND.DRAWS' // filext
     FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxLONGRbar+i-1,1:T,k,j)
     ! call savemat(theta, filename)
     filename  = 'LONGREALRATETREND'  // trim(int2str(i)) // filext
     CALL storeEstimatesOMP(theta,T,Ndraws,filename)
     WRITE (*,*) 'STORED LONGREALRATETREND'

     ! filename  = 'LONGNOMINALRATETREND.DRAWS' // filext
     FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxPIbar,1:T,k,j) + DRAWstates(ndxLONGRbar+1,1:T,k,j)
     ! call savemat(theta, filename)
     filename  = 'LONGNOMINALRATETREND'  // trim(int2str(i)) // filext
     CALL storeEstimatesOMP(theta,T,Ndraws,filename)
     WRITE (*,*) 'STORED LONGNOMINALRATETREND'
  end do

  filename  = 'INFLATIONGAP' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxPIgap,1:T,k,j) 
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED INFLATIONGAP'

  filename  = 'UGAP' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxUgap,1:T,k,j)
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED UGAP'

  filename  = 'INTGAP' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxINTgap,1:T,k,j)
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED INTGAP'

  do i = 1,Nyield
     filename  = 'LONGINTGAP' // trim(int2str(i)) // filext
     FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxLONGINTgap+i-1,1:T,k,j)
     CALL storeEstimatesOMP(theta,T,Ndraws,filename)
     WRITE (*,*) 'STORED LONGINTGAP', i
  end do

  if (doPInoise) then
     filename  = 'INFLATIONNOISE' // filext
     FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxPINOISE,1:T,k,j)
     CALL storeEstimatesOMP(theta,T,Ndraws,filename)
     WRITE (*,*) 'STORED INFLATIONNOISE'
  end if

  ! filename  = 'SHADOWRATE.DRAWS' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxSHADOWRATE,1:T,k,j)
  ! call savemat(theta, filename)
  filename  = 'SHADOWRATE' // filext
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED SHADOWRATE'

  filename  = 'NOMINALRATETREND' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxPIbar,1:T,k,j) + DRAWstates(ndxRbar,1:T,k,j)
  CALL storeEstimatesOMP(theta,T,Ndraws,filename)
  WRITE (*,*) 'STORED NOMINALRATETREND'


  DEALLOCATE(theta)

  ! STORE PARAMETERS

  ALLOCATE(theta(1,Ndraws))
  filename  = 'DELTAREALRATETREND' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWstates(ndxRbar,T,k,j) - DRAWstates(ndxRbar,0,k,j)
  CALL savevec(theta(1,:),filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED DELTAREALRATETREND'


  ALLOCATE(theta(Nf,Ndraws))
  filename  = 'F' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWf(:,k,j)
  CALL storeEstimatesOMP(theta,Nf,Ndraws,filename)
  ! filename  = 'F.draws' // filext
  ! CALL savemat(theta, filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED F'

  ALLOCATE(theta(Ngapvcv,Ndraws))
  filename  = 'GAPVCVCHOL' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWgapvcvchol(:,k,j)
  CALL savemat(transpose(theta),filename)
  ! filename  = 'GAPVCVCHOL' // filext
  ! CALL storeEstimatesOMP(theta,Ngapvcv,Ndraws,filename)
  DEALLOCATE(theta)
 
  ALLOCATE(theta(1,Ndraws))
  filename  = 'RBARVAR' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWrbarvar(:,k,j)
  CALL savemat(transpose(theta), filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED RBARVAR'

  ALLOCATE(theta(1,Ndraws))
  filename  = 'PIBARVAR' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWpibarvar(:,k,j)
  CALL savemat(transpose(theta), filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED PIBARVAR'

  ALLOCATE(theta(1,Ndraws))
  filename  = 'MAXLAMBDA' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWmaxlambda(:,k,j)
  ! CALL storeEstimates(theta,1,Ndraws,filename)
  CALL savevec(theta(1,:), filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED MAXLAMBDA'

  ! STORE DRAWS OF AVG TERM PREMIA
  ALLOCATE(theta(Nyield,Ndraws))
  filename  = 'AVGTERMPREMIA' // filext
  FORALL (k=1:Nsim,j=1:Nstreams) theta(:,(j-1) * Nsim + k) = DRAWavgtermpremia(:,k,j)
  CALL savemat(theta, filename)
  DEALLOCATE(theta)
  WRITE (*,*) 'STORED AVG TERM PREMIA'


  if (doPDF) then 
     ! collect 
     call hrulefill
     WRITE (*,*) 'COLLECTING PREDICTIVE DENSITY'
     call hrulefill

     filename = 'YPRED' // filext
     call savemat(ypred(:,horizons), filename)

     filename = 'YNANPRED' // filext
     call savemat(dble(yNaNpred(:,horizons)), filename)

     filename = 'YHORIZONS' // filext
     call savevec(dble(horizons), filename)


     ! DRAWY
     Ndraws = Nsim * Nstreams * Nforecastdraws

     ALLOCATE(theta(maxhorizons,Ndraws))
     ALLOCATE(yhatmedian(NNyy,maxhorizons))

     ! WRITE OUT YDRAW     
     DO i=1,NNyy
        FORALL (h=1:maxhorizons,k=1:Nsim,j=1:Nstreams,n=1:Nforecastdraws) theta(h,(j-1) * (Nsim * Nforecastdraws) + (k - 1) * Nforecastdraws + n) = DRAWy(i,h,n,k,j)

        filename  = 'YDRAW' // trim(int2str(i)) // filext
        CALL storeEstimatesOMP(theta,maxhorizons,Ndraws,filename)
        WRITE (*,*) 'STORED YDRAW', i

        ! note: theta is returned in sorted state
        yhatmedian(i,:) = theta(:,floor(real(Ndraws) * 0.5))
     END DO

     DEALLOCATE(theta)

     ! STORE MEDIAN FORECAST
     filename  = 'YHATMEDIAN' // filext
     CALL savemat(yhatmedian, filename)
     WRITE (*,*) 'STORED YHATMEDIAN'
     filename  = 'YHATMEDIANERROR' // filext
     yhatmedian = ypred - yhatmedian
     where (yNaNpred) yhatmedian = -999.0d0
     CALL savemat(yhatmedian, filename)
     WRITE (*,*) 'STORED YHATMEDIANERROR'
     DEALLOCATE(yhatmedian)

     ! STORE MEAN FORECAST
     ALLOCATE(yhatmean(NNyy,maxhorizons))
     forall (h=1:maxhorizons,i=1:NNyy) yhatmean(i,h) = sum(DRAWy(i,h,:,:,:)) / dble(Ndraws)
     filename  = 'YHATMEAN' // filext
     CALL savemat(yhatmean, filename)
     WRITE (*,*) 'STORED YHATMEAN'
     filename  = 'YHATMEANERROR' // filext
     yhatmean = ypred - yhatmean
     where (yNaNpred) yhatmean = -999.0d0
     CALL savemat(yhatmean, filename)
     WRITE (*,*) 'STORED YHATMEANERROR'
     DEALLOCATE(yhatmean)


     ! write out the scores in a separate loop
     WRITE (*,*) 'COMPUTING SCORES ... '
     ALLOCATE(crpsScore(NNyy,maxhorizons))
     ALLOCATE(logScore(NNyy,maxhorizons))

     !$OMP PARALLEL DO SHARED(theta, DRAWy, ypred, crpsScore, logScore, Nstreams, Nsim, Ndraws, NNyy) PRIVATE(theta1,h,k,j,n) DEFAULT(NONE) SCHEDULE(STATIC)
     DO i=1,NNyy
        ALLOCATE(theta1(Ndraws))
        do h = 1,maxhorizons
           FORALL (k=1:Nsim,j=1:Nstreams,n=1:Nforecastdraws) theta1((j-1) * (Nsim * Nforecastdraws) + (k - 1) * Nforecastdraws + n) = DRAWy(i,h,n,k,j)

           crpsScore(i,h) = crps(ypred(i,h), theta1, Ndraws)
           logScore(i,h)  = logGaussianScore(ypred(i,h), theta1, Ndraws)

        end do
        DEALLOCATE(theta1)
     END DO
     !$OMP END PARALLEL DO 
     ! DEALLOCATE(theta1)

     filename  = 'CRPS' // filext
     CALL savemat(crpsScore, filename)
     WRITE (*,*) 'STORE CRPSSCORE'

     filename  = 'LOGSCORE' // filext
     CALL savemat(logScore, filename)
     WRITE (*,*) 'STORE LOGSCORE'

     deallocate(crpsScore)
     deallocate(logScore)


     ! MV logGaussianScore
     ALLOCATE(logScoreMV(maxhorizons))
     ALLOCATE(theta(Ny,Ndraws))
     do h = 1,maxhorizons
        FORALL (i=1:Ny,k=1:Nsim,j=1:Nstreams,n=1:Nforecastdraws) theta(i,(j-1) * (Nsim * Nforecastdraws) + (k - 1) * Nforecastdraws + n) = DRAWy(i,h,n,k,j)

        logScoreMV(h) = logGaussianScoreMV(ypred(:,h), theta, Ny, Ndraws)
     end do

     filename  = 'MVLOGSCORE' // filext
     CALL savevec(logScoreMV, filename)
     WRITE (*,*) 'STORE MVLOGSCORE'


     DEALLOCATE(theta)
     DEALLOCATE(logScoreMV)

  end if



  ! ----------------------------------------------------------------------------
  ! FINISHED: STORE
  ! ----------------------------------------------------------------------------


  ! ----------------------------------------------------------------------------
  ! GELMAN
  ! ----------------------------------------------------------------------------

  ALLOCATE (GELMANstates(Nstates,T), GELMANf(Nf), GELMANgapvcvchol(Ngapvcv), GELMANrbarvar(1),  GELMANpibarvar(1), GELMANpinoisevar(1), STAT=status)
  ! IF (status /= 0) THEN
  !   WRITE (*,*) 'Allocation problem (Gelman statistics)'
  ! END IF

  CALL HRULEFILL
  WRITE (*,*) 'GELMAN STORAGE ALLOCATED'
  CALL HRULEFILL


  !$OMP PARALLEL SHARED(DRAWstates,GELMANstates,DRAWf,GELMANF,GELMANgapvcvchol, DRAWgapvcvchol)

  !$OMP DO 
  DO j = 1, Nstates
     if (j == ndxUgap) then
        GELMANstates(j,:) = 1.0d0
        forall (i=1:Nstreams,k=1:Nsim) DRAWstates(j,1:T,k,i) = DRAWstates(j,1:T,k,i) - y(1,:)
        print *,'max ugap delta:', maxval(abs(DRAWstates(j,1:T,:,:)))
     else
        DO k = 1,T
           call GelmanTest1(GELMANstates(j,k), Drawstates(j,k,:,:), Nsim, Nstreams)
        END DO
     end if

  END DO
  !$OMP END DO

  if (.not. doPInoise) GELMANstates(ndxPInoise,:) = 1.0d0
  !$OMP DO 
  DO j = 1, Nf
     call GelmanTest1(GELMANf(j), DRAWf(j,:,:), Nsim, Nstreams)
  END DO
  !$OMP END DO

  !$OMP DO 
  DO j = 1, Ngapvcv
     call GelmanTest1(GELMANgapvcvchol(j), DRAWgapvcvchol(j,:,:), Nsim, Nstreams)
  END DO
  !$OMP END DO

  call GelmanTest1(GELMANrbarvar(1), DRAWrbarvar(1,:,:), Nsim, Nstreams)

  call GelmanTest1(GELMANpibarvar(1), DRAWpibarvar(1,:,:), Nsim, Nstreams)

  if (doPInoise) call GelmanTest1(GELMANpinoisevar(1), DRAWpinoisevar(1,:,:), Nsim, Nstreams)


  !$OMP END PARALLEL 

  CALL HRULEFILL
  WRITE (*,*) 'GELMAN STATISTICS ARE DONE!'
  CALL HRULEFILL

  IF (ALL(ABS(GELMANstates - 1) < 0.2)) THEN
     WRITE(*,*) 'Gelman found decent convergence for the STATES'
  ELSE
     WRITE(*,*) 'STATES: GELMAN FAILURE, Max SRstat=', maxval(GELMANstates)
  END IF
  filename = 'GELMAN.states' // filext
  call savemat(GELMANstates, filename)

  IF (ALL(ABS(GELMANf - 1) < 0.2)) THEN
     WRITE(*,*) 'Gelman found decent convergence for F'
  ELSE
     WRITE(*,*) 'F: GELMAN FAILURE, Max SRstat=', maxval(GELMANf)
  END IF
  filename = 'GELMAN.f' // filext
  call savevec(GELMANf, filename)

  IF (ALL(ABS(GELMANgapvcvchol - 1) < 0.2)) THEN
     WRITE(*,*) 'Gelman found decent convergence for GAPVCVCHOL'
  ELSE
     WRITE(*,*) 'GAPVCV: GELMAN FAILURE, Max SRstat=', maxval(GELMANgapvcvchol)
  END IF
  filename = 'GELMAN.gapvcvchol' // filext
  call savevec(GELMANgapvcvchol, filename)

  IF (ALL(ABS(GELMANrbarvar - 1) < 0.2)) THEN
     WRITE(*,*) 'Gelman found decent convergence for RBARVAR'
  ELSE
     WRITE(*,*) 'RBARVAR: GELMAN FAILURE, Max SRstat=', maxval(GELMANrbarvar)
  END IF
  filename = 'GELMAN.rbarvar' // filext
  call savevec(GELMANrbarvar, filename)

  IF (ALL(ABS(GELMANpibarvar - 1) < 0.2)) THEN
     WRITE(*,*) 'Gelman found decent convergence for PIBARVAR'
  ELSE
     WRITE(*,*) 'PIBARVAR: GELMAN FAILURE, Max SRstat=', maxval(GELMANpibarvar)
  END IF
  filename = 'GELMAN.pibarvar' // filext
  call savevec(GELMANpibarvar, filename)

  if (doPInoise) then
     IF (ALL(ABS(GELMANpinoisevar - 1) < 0.2)) THEN
        WRITE(*,*) 'Gelman found decent convergence for PINOISEVAR'
     ELSE
        WRITE(*,*) 'PINOISEVAR: GELMAN FAILURE, Max SRstat=', maxval(GELMANpinoisevar)
     END IF
     filename = 'GELMAN.pinoisevar' // filext
     call savevec(GELMANpinoisevar, filename)
  end if
  DEALLOCATE (GELMANstates, GELMANf,  GELMANrbarvar, GELMANgapvcvchol, GELMANpibarvar, GELMANpinoisevar)

  ! ----------------------------------------------------------------------------
  ! FINISHED: GELMAN
  ! ----------------------------------------------------------------------------
  ! ----------------------------------------------------------------------------
  ! CLEANUP 1
  ! ----------------------------------------------------------------------------

  DEALLOCATE (DRAWmaxlambda, DRAWstates, DRAWf)
  DEALLOCATE (DRAWpibarvar, DRAWpinoisevar, DRAWrbarvar)
  DEALLOCATE (DRAWgapvcvchol)
  DEALLOCATE (DRAWavgtermpremia)

  ! DEALLOCATE (DRAWypdf, DRAWyforecast, DRAWymedian, DRAWyproblb, DRAWycondvar)
  DEALLOCATE (DRAWy)
  DEALLOCATE (y, yNaN,zlb)
  DEALLOCATE (ypred, yNaNpred)
  DEALLOCATE (Ef0,sqrtVf0)
  DEALLOCATE (gapvcvT)

  ! ----------------------------------------------------------------------------
  ! CLEANUP 2
  ! ----------------------------------------------------------------------------
  ! VSLstreams
  errcode = vsldeletestream(VSLdefaultstream)     

  call hrulefill
  WRITE(*,*) 'DONE. BYE, BYE. (' // trim(adjustl(filext)) // ')'
  call hrulefill

  STOP

CONTAINS

  SUBROUTINE minnesotaVCVsqrt(sqrtVf0, N, p, lambda1, lambda2)

    integer, intent(in) :: N, p
    double precision, intent(inout), dimension(N*N*p,N*N*p) :: sqrtVf0
    double precision, intent(in) :: lambda1, lambda2

    integer :: ndxVec, ndxLHS = 1, ndxLag = 1, ndxRHS = 1
    integer :: Nf

    Nf = N * N * p
    sqrtVf0 = 0.0d0

    ndxVec = 0
    do ndxLHS = 1,N
       do ndxLag = 1,p
          do ndxRHS = 1,N

             ndxVec = ndxVec + 1

             if (ndxLHS == ndxRHS) then
                sqrtVf0(ndxVec,ndxVec) = lambda1 / dble(ndxLag)
             else
                sqrtVf0(ndxVec,ndxVec) = lambda1 * lambda2 / dble(ndxLag)
             end if

          end do
       end do
    end do

  END SUBROUTINE minnesotaVCVsqrt

  SUBROUTINE getarguments(ZLBrejection,doPDF,doPInoise, doZLBasZeroes, T, T0, gapOrderKey, datalabel, Nyield, p, Nsim, burnin, Nstreams)

    INTENT(INOUT) ZLBrejection, doPDF, doPInoise, doZLBasZeroes, T, T0, datalabel, Nyield, p, Nsim, burnin, Nstreams

    integer, intent(inout) :: gapOrderKey

    INTEGER :: T, T0, Nsim, Nyield, p, burnin, Nstreams, dummy
    LOGICAL :: ZLBrejection,doPDF,doPInoise, doZLBasZeroes
    INTEGER :: counter
    CHARACTER (LEN=100) :: datalabel
    CHARACTER(len=32) :: arg

    counter = 0

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          ZLBrejection = .true.
       else
          ZLBrejection = .false.
       end if
    END IF


    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          doPDF = .true.
       else
          doPDF = .false.
       end if
    END IF


    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          doPInoise = .true.
       else
          doPInoise = .false.
       end if
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') dummy
       if (dummy > 0) then
          doZLBasZeroes = .true.
       else
          doZLBasZeroes = .false.
       end if
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') T
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') T0
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg) 
       READ(arg, '(i20)') gapOrderKey
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, datalabel) 
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg)
       READ(arg, '(i20)') Nyield
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg)
       READ(arg, '(i20)') p
    END IF


    counter = counter + 1
    IF (command_argument_count() >= counter) THEN
       CALL get_command_argument(counter, arg)
       READ(arg, '(i20)') Nsim
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN    
       CALL get_command_argument(counter, arg)
       READ(arg, '(i20)') Burnin
    END IF

    counter = counter + 1
    IF (command_argument_count() >= counter) THEN    
       CALL get_command_argument(counter, arg)
       READ(arg, '(i20)') Nstreams
    END IF

  END SUBROUTINE getarguments



  ! -----------------------------------------------------------------
  SUBROUTINE readdata(y,filename,Ny,T,T0)
    IMPLICIT NONE

    INTENT(IN) :: filename,Ny,T,T0
    INTENT(INOUT) :: y
    CHARACTER (LEN=200) :: filename
    CHARACTER (LEN=500) :: fmtstr

    INTEGER i, T, T0, Ny
    DOUBLE PRECISION :: y(Ny,T), data(Ny,T)


    fmtstr = es30d16(Ny)
    !Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')
    ! skio first T0 lines
    DO i=1,T0
       READ(4,*) 
    END DO
    DO i=1,T
       READ(4,fmtstr) data(:,i)
       ! print *, i, data(:,i)
    END DO
    CLOSE(UNIT=4)

    ! transform data
    y = data ! trivial, since already done in matlab

  END SUBROUTINE readdata
  ! -----------------------------------------------------------------

  ! -----------------------------------------------------------------
  SUBROUTINE readnandata(nanny,filename,Ny,T,T0)
    IMPLICIT NONE

    INTENT(IN) :: filename,T,T0,Ny
    INTENT(INOUT) :: nanny
    CHARACTER (LEN=100) :: filename
    CHARACTER (LEN=500) :: fmtstr

    LOGICAL, DIMENSION(:,:) :: nanny
    INTEGER :: work(Ny)

    INTEGER i, j, T, T0, Ny

    fmtstr = '(I2' // repeat(',I2', Ny-1) // ')'

    !Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')
    DO i=1,T0
       READ(4,*) 
    END DO
    DO i=1,T
       READ(4,fmtstr) (work(j), j=1,Ny)
       WHERE (work == 1) 
          nanny(:,i) = .TRUE.
       ELSEWHERE
          nanny(:,i) = .FALSE.
       END WHERE
    END DO

    CLOSE(UNIT=4)

  END SUBROUTINE readnandata
  ! -----------------------------------------------------------------

  ! -----------------------------------------------------------------
  function readpreddata(filename,Ny,NNyy,maxhorizons,Tdata,T) result(ypred)
    IMPLICIT NONE

    INTENT(IN) :: filename,Ny,NNyy,maxhorizons,Tdata,T

    CHARACTER (LEN=200) :: filename
    CHARACTER (LEN=500) :: fmtstr

    INTEGER row, T, Ny, NNyy, maxhorizons, Tdata
    DOUBLE PRECISION :: ypred(NNyy,maxhorizons), data(Ny,Tdata)

    ypred = dble(-999) 

    fmtstr = es30d16(Ny)

    ! Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')

    ! read all data
    do row=1,Tdata
       READ(4,fmtstr) (data(k,row), k=1,Ny) 
    end do
    CLOSE(UNIT=4)

    ! extract ypred
    row = 1
    DO while (T + row <= min(Tdata,T+maxhorizons)) 
       ypred(1:Ny,row) = data(:,T+row)
       ! construct 4q-MA of inflation
       ypred(Ny+1,row) = sum(data(2,T+row-3:T+row)) / 4.0d0
       ! add shadow rate
       ypred(Ny+2,row) = data(3,T+row)
       row = row + 1
    END DO




  end function readpreddata
  ! -----------------------------------------------------------------

  ! -----------------------------------------------------------------
  function readprednandata(filename,Ny,NNyy,maxhorizons,Tdata,T) result(nanny)

    IMPLICIT NONE

    INTENT(IN) :: filename,Ny, NNyy,maxhorizons,Tdata,T

    CHARACTER (LEN=100) :: filename
    CHARACTER (LEN=500) :: fmtstr

    INTEGER row, k, Ny, NNyy, maxhorizons, Tdata, T
    LOGICAL, DIMENSION(NNyy,maxhorizons) :: nanny
    INTEGER :: data(Ny,Tdata)

    fmtstr = '(I2' // repeat(',I2', Ny-1) // ')'

    nanny = .TRUE.

    ! Open File for reading
    OPEN (UNIT=4, FILE=filename, STATUS='OLD', ACTION='READ')

    ! read all data
    do row=1,Tdata
       READ(4,fmtstr) (data(k,row), k=1,Ny) 
    end do
    CLOSE(UNIT=4)

    ! extract yNaNpred
    row = 1
    DO while (T + row <= min(Tdata,T+maxhorizons)) 
       WHERE (data(:,T+row) == 1) 
          nanny(1:Ny,row) = .TRUE.
       ELSEWHERE
          nanny(1:Ny,row) = .FALSE.
       END WHERE
       ! 4q MA of inflation
       if (any(data(2,T+row-3:T+row) == 1)) then
          nanny(Ny+1,row) = .TRUE.
       else
          nanny(Ny+1,row) =- .FALSE.
       end if
       ! shadow rate
       nanny(Ny+2,row) = nanny(3,row)

       row = row + 1
    END DO

  end function readprednandata
  ! -----------------------------------------------------------------


END PROGRAM main

! -----------------------------------------------------------------

! @\newpage\subsection{thissampler}@
SUBROUTINE thissampler(ZLBrejection, ELBound, doPDF, doPInoise, gapOrderKey, T, Ny, Nyield, y, yNaN, zlb, NNyy, NNxx, DRAWy, Nforecastdraws, maxhorizons, DRAWavgtermpremia, DRAWstates, Nstates, Nx, Nw, Nbar, Ngap, p, DRAWf, Nf, Ef0, sqrtVf0, DRAWmaxlambda, DRAWgapvcvchol, Ngapvcv, gapvcvT, gapvcvDof, DRAWrbarvar, rbarvarT, rbarvarDof, DRAWpibarvar, pibarvarT, pibarvarDof, DRAWpinoisevar, pinoisevarT, pinoisevarDof, Nsim, Burnin,VSLstream,timer)

  use embox, only: hrulefill, savemat, savevec, int2str
  use blaspack, only: eye, vectortimesmatrix, predictstate, vech
  use gibbsbox, only: VARmaxroot, bayesVAR, igammadraw, variancedraw, iwishcholdraw, vcvcholDrawTR
  use statespacebox, only: DLYAP, samplerA3B3C3nanscalar
  use densitybox, only : predictivedensity
  use vslbox
  use omp_lib
  use timerbox

  IMPLICIT NONE

  INTENT(INOUT) :: DRAWstates, DRAWf, VSLstream, timer
  INTENT(INOUT) :: DRAWgapvcvchol, DRAWpibarvar, DRAWpinoisevar, DRAWrbarvar
  INTENT(INOUT) :: DRAWavgtermpremia
  ! INTENT(INOUT) :: DRAWypdf, DRAWyforecast, DRAWymedian, DRAWyprobLB, DRAWycondvar
  INTENT(INOUT) :: DRAWy
  INTENT(IN)    :: ZLBrejection, doPDF, doPInoise, T, Ny, Nyield, y, yNaN, zlb, Nforecastdraws, maxhorizons, NNyy, NNxx, Nstates, Nx, Nw, Nbar, Ngap, p, Nf, Nsim, Burnin, Ef0, sqrtVf0
  INTENT(IN)    :: Ngapvcv, rbarvarT, rbarvarDof, pibarvarT, pibarvarDof, pinoisevarT, pinoisevarDof, gapvcvT, gapvcvDof 

  double precision, intent(in) :: ELBound
  integer, intent(in) :: gapOrderKey

  LOGICAL :: ZLBrejection, doPDF, doPInoise

  INTEGER :: J, I, K, T, Nsim, thisdraw, joflastdraw, Burnin, TotalSim, Nstates, Nx, Nw, Nbar, Ngap, Ngaplags, Ny, Nf, p, status
  INTEGER :: Ngapvcv

  double precision :: sharedone

  INTEGER :: ndxPIbar, ndxRbar, ndxLONGRbar, ndxUgap, ndxINTgap, ndxLONGINTgap, Nyield, ndxPIgap, ndxPInoise, ndxGapStart, ndxGapStop, ndxGapLagStop
  INTEGER :: ndxShockPIbar, ndxShockRbar, ndxShockGapStart, ndxShockPIgap, ndxShockUgap, ndxShockINTgap, ndxShockLONGINTgap, ndxShockPInoise
  INTEGER :: ndxShockGapStop
  ! INTEGER :: ndxSVpibar, ndxSVpigap, ndxSVugap, ndxSVintgap, ndxSVlongintgap, ndxSVpinoise
  INTEGER :: yndxLONGINT, yndxInflation, yndxPolicyrate, yndxUgap

  ! forecast stuff
  ! integer :: Nhorizons, horizons(Nhorizons)
  integer :: maxhorizons
  ! double precision, dimension(NNyy, maxhorizons) :: ypred
  ! logical :: yNaNpred(Ny, maxhorizons)
  double precision, dimension(NNyy) :: ytrunclb
  logical, dimension(NNyy) :: ytruncated
  ! double precision, dimension(NNyy, Nhorizons, Nsim) :: DRAWypdf, DRAWyforecast, DRAWymedian, DRAWyprobLB, DRAWycondvar
  integer :: Nforecastdraws
  double precision, dimension(NNyy, maxhorizons, Nforecastdraws, Nsim) :: DRAWy

  integer :: NNyy, NNxx 
  double precision :: AA(NNxx,NNxx), BB(NNxx,Nw), CC(NNyy,NNxx), xx(NNxx)

  ! OTHER
  type (vsl_stream_state) :: VSLstream
  type(progresstimer) :: timer

  DOUBLE PRECISION, DIMENSION(Ny,T) :: y
  LOGICAL, DIMENSION(Ny,T) :: yNaN, zlb
  DOUBLE PRECISION, DIMENSION(Nstates,0:T,Nsim) :: DRAWstates
  DOUBLE PRECISION, DIMENSION(Nyield,Nsim) :: DRAWavgtermpremia
  DOUBLE PRECISION, DIMENSION(Nf,Nsim) :: DRAWf
  DOUBLE PRECISION, DIMENSION(1,Nsim) :: DRAWmaxlambda
  DOUBLE PRECISION, DIMENSION(Ngapvcv,Nsim) :: DRAWgapvcvchol
  DOUBLE PRECISION, DIMENSION(1,Nsim) :: DRAWrbarvar
  DOUBLE PRECISION, DIMENSION(1,Nsim) :: DRAWpibarvar, DRAWpinoisevar


  DOUBLE PRECISION :: Ex0(Nx), sqrtVx0(Nx,Nx), A(Nx,Nx,T), B(Nx,Nw), Bsv(Nx,Nw,T), C(Ny,Nx,T), Ci(Nx) ! ,gap0variance(Ngap * p, Ngap * p)
  DOUBLE PRECISION :: f(Nf), Ef0(Nf), sqrtVf0(Nf,Nf), iVf0(Nf,Nf)

  DOUBLE PRECISION :: rbarvar, rbarvarT
  INTEGER :: rbarvarDof
  DOUBLE PRECISION :: pibarvar, pibarvarT, pinoisevar, pinoisevarT, gapVCVchol(Ngap,Ngap), gapvcvT(Ngap,Ngap), invgapVCV(Ngap,Ngap)
  INTEGER :: pibarvarDof, pinoisevarDof, gapvcvDof


  DOUBLE PRECISION :: maxlambda, SigmaStarT(Nx,Nx)
  DOUBLE PRECISION :: istar(0:T), rr(0:T), xhat(Nx)

  DOUBLE PRECISION :: gapshock(T,Ngap), gap(-(p-1):T,Ngap)

  ! INTEGER :: longrateHorizon 

  DOUBLE PRECISION, DIMENSION(Nx, 0:T) :: x
  DOUBLE PRECISION, DIMENSION(Nx, T)   :: xshock 

  ! stack management
  DOUBLE PRECISION, PARAMETER :: unity = .999
  integer, parameter :: stacksize = 10, maxShakes = 10, zlbShakes = 100
  integer :: maxRejections 
  double precision, dimension(Nf,stacksize) :: PREV_F
  double precision, dimension(Ngap,Ngap,stacksize) :: PREV_GAPVCVCHOL
  double precision, dimension(stacksize) :: PREV_RBARVAR
  double precision, dimension(stacksize) :: PREV_PIBARVAR, PREV_PINOISEVAR


  integer, dimension(stacksize) :: stackRegister
  integer :: lastInStack, shakes, stackResetCount, rejectionCount, nominaltrendELBcount
  logical :: OK 
  CHARACTER (LEN=200) :: resetmsg

  ! VSL
  INTEGER :: errcode
  INTEGER, PARAMETER :: VSLmethodGaussian = 0, VSLmethodUniform = 0

  ! state space bounds
  DOUBLE PRECISION, PARAMETER :: maxabsRbar = 1000.0d0

  ! CHARACTER (LEN=200) :: filename
  CHARACTER (LEN=100) :: progresscomment

  ! openmp (just for debugging)
  INTEGER :: TID

  TID = 0
  !$ TID = OMP_GET_THREAD_NUM()

  stackRegister = -1 ! dummy value for unregistered stack
  stackResetCount = -1

  Ngaplags = Ngap * p
  TotalSim = Burnin + Nsim ! only used for updating the progress bar
  maxRejections = TotalSim / 4 * maxShakes

  ! prepare state space

  ! y: ugap, inflation, fed funds, long-bond yields
  yndxUgap        = 1
  yndxInflation   = 2
  yndxPolicyRate  = 3
  yndxLONGINT     = 4


  ! x: pibar, rbar, gaps, ... gaps(lags), pinoise
  ndxPIbar        = 1
  ndxRbar         = 2
  ndxLONGRbar     = 3
  ndxPIgap        = ndxLONGRbar + Nyield
  ndxUgap         = ndxPIgap + 1
  ndxINTgap       = ndxUgap + 1
  ndxLONGINTgap   = ndxINTgap + 1

  ndxGapStart     = ndxPIgap
  ndxGapStop      = ndxLONGINTgap + (Nyield - 1)
  ndxGapLagStop   = (ndxPIgap - 1) + (Ngap * p)

  ndxPInoise      = ndxGapLagStop + 1

  if (ndxPInoise .ne. Nx) then
     print *, 'indices are off'
     print *, 'Nx:', Nx
     print *, 'ndxPInoise:', ndxPInoise
     stop 1
  end if

  ! ndxshock (order SV shocks first)
  ndxShockPIbar      = 1
  ndxShockGapStart   = ndxShockPibar + 1
  ndxShockGapStop    = ndxShockPibar + Ngap

  ndxShockPInoise    = ndxShockPIbar + Ngap + 1
  ndxShockRbar       = ndxShockPInoise + 1

  ! ordering gap shocks
  select case (gapOrderKey)
  case (1234)
     ! x
     ndxPIgap        = (ndxGapStart - 1) + 1
     ndxUgap         = (ndxGapStart - 1) + 2
     ndxINTgap       = (ndxGapStart - 1) + 3
     ndxLONGINTgap   = (ndxGapStart - 1) + 4
     ! shock     
     ndxShockPIgap      = (ndxShockGapStart - 1) + 1
     ndxShockUgap       = (ndxShockGapStart - 1) + 2
     ndxShockINTgap     = (ndxShockGapStart - 1) + 3
     ndxShockLONGINTgap = (ndxShockGapStart - 1) + 4

  case (2134)
     ! x
     ndxPIgap        = (ndxGapStart - 1) + 2
     ndxUgap         = (ndxGapStart - 1) + 1
     ndxINTgap       = (ndxGapStart - 1) + 3
     ndxLONGINTgap   = (ndxGapStart - 1) + 4
     ! shock     
     ndxShockPIgap      = (ndxShockGapStart - 1) + 2
     ndxShockUgap       = (ndxShockGapStart - 1) + 1
     ndxShockINTgap     = (ndxShockGapStart - 1) + 3
     ndxShockLONGINTgap = (ndxShockGapStart - 1) + 4

  case (3214)
     ! x
     ndxPIgap        = (ndxGapStart - 1) + 3
     ndxUgap         = (ndxGapStart - 1) + 2
     ndxINTgap       = (ndxGapStart - 1) + 1
     ndxLONGINTgap   = (ndxGapStart - 1) + 4
     ! shock     
     ndxShockPIgap      = (ndxShockGapStart - 1) + 3
     ndxShockUgap       = (ndxShockGapStart - 1) + 2
     ndxShockINTgap     = (ndxShockGapStart - 1) + 1
     ndxShockLONGINTgap = (ndxShockGapStart - 1) + 4

  case (4321)
     ! x
     ndxPIgap        = (ndxGapStart - 1) + 4 + (Nyield - 1)
     ndxUgap         = (ndxGapStart - 1) + 3 + (Nyield - 1)
     ndxINTgap       = (ndxGapStart - 1) + 2 + (Nyield - 1)
     ndxLONGINTgap   = (ndxGapStart - 1) + 1
     ! shock     
     ndxShockPIgap      = (ndxShockGapStart - 1) + 4 + (Nyield - 1)
     ndxShockUgap       = (ndxShockGapStart - 1) + 3 + (Nyield - 1)
     ndxShockINTgap     = (ndxShockGapStart - 1) + 2 + (Nyield - 1)
     ndxShockLONGINTgap = (ndxShockGapStart - 1) + 1 

  case (1324)
     ! x
     ndxPIgap        = (ndxGapStart - 1) + 1
     ndxUgap         = (ndxGapStart - 1) + 3
     ndxINTgap       = (ndxGapStart - 1) + 2
     ndxLONGINTgap   = (ndxGapStart - 1) + 4
     ! shock     
     ndxShockPIgap      = (ndxShockGapStart - 1) + 1
     ndxShockUgap       = (ndxShockGapStart - 1) + 3
     ndxShockINTgap     = (ndxShockGapStart - 1) + 2
     ndxShockLONGINTgap = (ndxShockGapStart - 1) + 4


  case default
     print *,'gapOrderKey= ', gapOrderKey, ' not recognized'
     stop 1
  end select

  A = 0.0d0
  ! unit roots for bar  
  FORALL(i=1:T,k=1:Nbar) A(k,k,i) = 1.0d0

  ! kompanion for gap
  FORALL (i = 1 : (Ngap * (p - 1)))
     A(ndxGapStop+i,ndxGapStart-1+i,:) = 1.0d0
  END FORALL

  ! prior over initial states
  Ex0           = 0.0d0
  call eye(sqrtVx0, 1.0d1)

  ! joint prior over pibar, and ibar; transformed into prior over pibar and rbar
  Ex0(ndxPIbar)     = 2.0d0 ! rough level for pibar
  Ex0(ndxRbar)      = 2.0d0 ! rough level for rbar
  forall (i = 0 : Nyield - 1) Ex0(ndxLONGRbar+i)  = 2.0d0 + dble(i+1) * 0.5d0 ! rough level for rbar
  ! sqrtVx0(ndxPIbar,ndxPIbar)     = 4.0d0
  ! sqrtVx0(ndxRbar,ndxPIbar)      = -  sqrtVx0(ndxPIbar,ndxPIbar)
  ! forall (i = 0 : Nyield - 1) sqrtVx0(ndxLONGRbar+i,ndxPIbar)  = -  sqrtVx0(ndxPIbar,ndxPIbar)

  Bsv = 0.0d0
  B   = 0.0d0
  ! unit loadings on SV shocks
  B(ndxPIbar,ndxshockPIBar)     = 1.0d0
  B(ndxPIgap,ndxshockPIgap)     = 1.0d0

  ! B(ndxRbar,ndxshockRBar)       = 1.0d0
  ! B(ndxLONGRbar,ndxshockRBar)   = 1.0d0

  B(ndxUgap,ndxshockUgap)               = 1.0d0
  B(ndxINTgap,ndxshockINTgap)           = 1.0d0
  forall (i = 0 : Nyield - 1) B(ndxLONGINTgap+i,ndxshockLONGINTgap+i)   = 1.0d0

  if (doPInoise) B(ndxPInoise,ndxshockPInoise) = 1.0d0

  ! Measurement
  C = 0.0d0

  ! u
  C(yndxUgap,ndxUgap,:)   = 1.0d0 

  ! pi
  C(yndxInflation,ndxPIbar,:)   = 1.0d0    
  C(yndxInflation,ndxPIgap,:)   = 1.0d0
  if (doPInoise) C(yndxInflation,ndxPInoise,:) = 1.0d0    

  ! i
  C(yndxPolicyrate,ndxRbar,:)   = 1.0d0    
  C(yndxPolicyrate,ndxPIbar,:)  = 1.0d0    
  C(yndxPolicyrate,ndxINTgap,:) = 1.0d0    

  ! longi
  forall (i = 0 : Nyield - 1) C(yndxLONGINT+i,ndxLONGRbar+i,:)   = 1.0d0    
  forall (i = 0 : Nyield - 1) C(yndxLONGINT+i,ndxPIbar,:)        = 1.0d0    
  forall (i = 0 : Nyield - 1) C(yndxLONGINT+i,ndxLONGINTgap+i,:) = 1.0d0    

  ! i for Ct
  Ci = 0.0d0
  Ci(ndxRbar)   = 1.0d0    
  Ci(ndxPIbar)  = 1.0d0    
  Ci(ndxINTgap) = 1.0d0    


  ! prediction state space
  ! - init
  AA = 0.0d0
  BB = 0.0d0
  CC = 0.0d0
  ! - copy original state space block
  AA(1:Nx,1:Nx) = A(:,:,T)
  CC(1:Ny,1:Nx) = C(:,:,T)
  BB(1:Nx,:)    = B
  ! - expand state transition
  AA(Nx+1,1:Nx) = C(yndxInflation,:,T)
  forall (j=2:3) AA(Nx+j,Nx+j-1) = 1.0d0
  ! - define 4q inflation 
  CC(Ny+1,1:Nx)      = C(yndxInflation,:,T) / 4.0d0
  CC(Ny+1,Nx+1:Nx+3) = 1.0d0 / 4.0d0
  ! CC(Ny+1,Nx+1) = 1.0d0

  ! - define shadow rate
  CC(Ny+2,1:Nx) = C(yndxPolicyRate,:,T)

  ! - plug data on lagged inflation into the xx state
  xx            = 0.0d0

  ytruncated    = .false.
  ytruncated(yndxPolicyrate) = .true.
  forall (i=0:Nyield-1) ytruncated(yndxLONGINT+i)    = .true.


  ytrunclb = ELBound

  ! prepare C for missing values
  DO k=1,T
     DO i = 1, Ny
        if (yNaN(i,k)) C(i,:,k) = 0.0d0
        if (yNaN(i,k) .AND. y(i,k) /= 0.0d0 ) then
           write (*,*) 'YNAN PATTERN DOES NOT MATCH ZEROS IN Y'
        end if
     END DO
  END DO

  iVf0 = sqrtVf0
  call DPOTRI('U', Nf, iVf0, Nf, status)
  if (status /= 0) then
     write(*,*) 'DPOTRI ERROR, INFO: ', status, ' [iVf0]'
     stop 1
  end if

  shakes = 1
  j = 1
  lastInStack = 1 ! redundant, but avoids compiler warning
  resetmsg = 'DRAW 0'
  rejectionCount = 0
  thisdraw = 1

  DO WHILE (thisdraw <= Nsim)

     ! WRITE (*,*) 'STEP ', j

     IF (j == 1) THEN

        call initprogressbar(timer,timer%wait,timer%rank)
        stackRegister   = -1
        stackResetCount = stackResetCount + 1

        IF (rejectionCount > 1) THEN
           call hrulefill
           WRITE (*, '(" RE-INIT STREAM ", i2, " (reset count = ", i4, ", rejection count = ", i8, ", ", a10, ")")')  timer%rank, stackResetCount, rejectionCount, trim(resetmsg)
           call hrulefill
        END IF

        rejectionCount = 0
        nominaltrendELBcount = 0

        resetmsg = 'NIL'

        ! init gapVCV
        if (gapVCVDof > 0) then
           call iwishcholDraw(gapvcvchol, gapvcvT, gapvcvDof, Ngap, VSLstream)
        else
           call eye(invgapvcv) ! abusing invGapVCV as placeholder for an identity matrix
           call iwishcholDraw(gapvcvchol, invgapvcv, Ngap + 2, Ngap, VSLstream)
        end if
        ! init rbarvar
        if (rbarvarDof > 0) then
           call igammaDraw(rbarvar, rbarvarT, rbarvarDof, VSLstream)
        else
           call igammaDraw(rbarvar, 1.0d0 ** 2, 1, VSLstream)
        end if
        ! init pibarvar
        if (pibarvarDof > 0) then
           call igammaDraw(pibarvar, pibarvarT, pibarvarDof, VSLstream)
        else
           call igammaDraw(pibarvar, 0.1d0 ** 2, 3, VSLstream)
        end if
        ! init pinoisevar
        if (pinoisevarDof > 0) then
           call igammaDraw(pinoisevar, pinoisevarT, pinoisevarDof, VSLstream)
        else
           call igammaDraw(pinoisevar, 0.1d0 ** 2, 3, VSLstream)
        end if

        ! init VAR coefficients f
        DO
           errcode = vdrnggaussian(VSLmethodGaussian, VSLstream, Nf, f, 0.0d0, 1.0d0)
           CALL DTRMV('U', 'T', 'N', Nf, sqrtVf0, Nf, f, 1)
           f = f + Ef0
           call VARmaxroot(maxlambda, f, Ngap, p)
           OK = maxlambda < unity
           IF (OK) EXIT
        END DO

        ! init stack
        lastInStack = 1

        PREV_RBARVAR(lastInStack)       = rbarvar
        PREV_PIBARVAR(lastInStack)      = pibarvar
        PREV_PINOISEVAR(lastInStack)    = pinoisevar

        PREV_GAPVCVCHOL(:,:,lastInStack)    = gapvcvchol

        PREV_F(:,lastInStack)           = f


        stackRegister(lastInStack)   = j

        ! WRITE (*,*) 'STREAM ', timer%rank, 'STEP ', j, '[ DONE INIT ]'
        ! WRITE (*,*) 'STREAM ', timer%rank, 'LAST RESET WAS ', resetmsg
        ! resetmsg = 'NIL'


     ELSE ! j > 1

        rbarvar       = PREV_RBARVAR(lastInStack)
        pibarvar      = PREV_PIBARVAR(lastInStack)
        pinoisevar    = PREV_PINOISEVAR(lastInStack)

        gapvcvchol    = PREV_GAPVCVCHOL(:,:,lastInStack)

        f             = PREV_F(:,lastInStack) 

        if (j == BURNIN) call initprogressbar(timer,timer%wait,timer%rank)

     END IF ! j == 1

     ! ---------------------------------------------------------------------------
     ! SMOOTHING SAMPLER
     ! ---------------------------------------------------------------------------
     B(ndxRbar, ndxShockRbar)     = sqrt(rbarvar)
     forall (i = 0 : Nyield - 1) B(ndxLONGRbar+i, ndxShockRbar) = sqrt(rbarvar)

     B(ndxpibar, ndxShockPIbar)      = sqrt(pibarvar)
     B(ndxpinoise, ndxShockPInoise)  = sqrt(pinoisevar)

     ! inflation gap loading
     B(ndxgapstart:ndxgapstop,ndxshockgapstart:ndxshockgapstop) = gapVCVchol ! NOTE: upper LEFT choleski factor
     Bsv    = 0.0d0
     forall (i=1:T) Bsv(:,:,i) = B

     ! Fill in VAR coefficients
     FORALL (i=1:T) A(ndxGapStart:ndxGapStop,ndxGapStart:ndxGapLagStop,i) = transpose(reshape(f, (/ Ngap * p, Ngap /)))

     OK = .FALSE.
     i = 0
     DO WHILE (.NOT. OK .AND. (i < zlbShakes))

        i = i + 1
        ! print *, 'entering abc' 
        call samplerA3B3C3nanscalar(x,xshock,SigmaStarT,y,yNaN,T,Ny,Nx,Nw,A,Bsv,C,Ex0,sqrtVx0,VSLstream,errcode)
        ! print *, 'exiting abc'

        ! if (TID == 0) errcode = 1
        if (errcode /= 0) then

           OK = .FALSE.
           print *, 'oops', i

           call savemat(A(:,:,1), 'A.debug')
           call savemat(C(:,:,1), 'C.debug')
           call savemat(A(:,:,2), 'A2.debug')
           call savemat(B(:,:), 'B.debug')
           call savemat(Bsv(:,:,1), 'B1.debug')
           call savemat(Bsv(:,:,2), 'B2.debug')
           call savemat(C(:,:,2), 'C2.debug')
           call savevec(Ex0, 'Ex0.debug')
           call savemat(sqrtVx0, 'sqrtVx0.debug')
           call savemat(x, 'x.debug')
           call savemat(xshock, 'xshock.debug')
           call savemat(y, 'y.debug')
           ! call savemat(gap0variance, 'gapvariance')

           ! print *, 'ndxUgap', ndxugap
           stop 1 

        else
           OK = .true.
        end if

        ! if (.not. OK) exit
        ! if (.not. OK) print *,'what am i doing here?'

        ! construct real rate and Vol of rgap
        rr = 0.0d0
        IF (j > BURNIN) THEN

           ! real rate
           xhat  = predictstate(Nx, A(:,:,1), x(:,0), 1)
           rr(0) = x(ndxRbar,0) + x(ndxINTgap,0) - xhat(ndxPIgap)
           DO k=1,T
              xhat  = predictstate(Nx, A(:,:,k), x(:,k), 1)
              if (zlb(yndxPolicyrate,k)) then
                 rr(k) = ELBound - x(ndxPIbar,k) - xhat(ndxPIgap) 
              else
                 rr(k) = x(ndxRbar,k) + x(ndxINTgap,k) - xhat(ndxPIgap)
              end if
           END DO

        END IF


        istar = x(ndxRbar,:) + x(ndxPIbar,:) + x(ndxINTgap,:) 

        ! implement lower bound on nominal rate trend
        OK = .true.
        ! if (ZLBrejection) then ! TODO: check this condition
        !    OK = ALL(x(ndxRbar,:) + x(ndxPIbar,:) .ge. ELBound) 
        ! end if

        OK = OK .AND. ALL(abs(x(ndxRbar,:)) .lt. maxabsRbar)

        if (.NOT. OK) then
           resetmsg = 'RBAR'
           nominaltrendELBcount = nominaltrendELBcount + 1
           ! WRITE (*,*) 'STREAM ', timer%rank, 'hitting ', resetmsg
        else if (ZLBrejection) then 
           OK = ALL((.NOT. zlb(yndxPolicyrate,:)) .OR. (istar(1:T) < ELBound))
           IF (.NOT. OK) resetmsg = 'ZLB'
        end if

     END DO


     IF (OK) THEN

        ! ---------------------------------------------------------------------------
        ! GAP VAR
        ! ---------------------------------------------------------------------------

        ! a: construct inverse of gapVCV
        call DTRTRI('U', 'N', Ngap, gapVCVchol, Ngap, status)         
        if (status /= 0) then
           write(*,*) 'DTRTRI ERROR, INFO: ', status, ' [GAPVCV - GibbsSampler]'
           stop 1
        end if
        call dsyrk('U', 'T', Ngap, Ngap, 1.0d0, gapVCVchol, Ngap, 0.0d0, invGapVCV, Ngap)

        ! b:  collect gap vector
        FORALL (i=1:p) gap(1-i,:) = x(ndxGapStart+(i-1)*Ngap:ndxGapStop+(i-1)*Ngap,0)
        gap(1:T,:)                = transpose(x(ndxGapStart:ndxGapStop,1:T))

        ! c: draw VAR coefficients
        call bayesVAR(f, gapshock, p, gap, Ngap, T, invGapVCV, Ef0, iVf0, VSLstream)
        if (any(isnan(f))) then
           write(*,*) 'NaN draws from bayesVAR'
           stop 1
        end if

        ! d) check stability
        call VARmaxroot(maxlambda, f, Ngap, p)

        OK = maxlambda < unity
        IF (.NOT. OK) resetmsg = 'VAR'

        xshock(ndxGapStart:ndxGapStop,:) = transpose(gapshock)

        ! print *, 'done VAR'

     END IF

     IF (OK) THEN 

        ! --------------------------------------------------------------------------
        ! rbarvar
        ! --------------------------------------------------------------------------
        call varianceDraw(rbarvar, rbarvarT, rbarvarDof, xshock(ndxRbar,:), T, VSLstream)

        if (rbarvar .gt. maxabsRbar) then
           OK = .false.
           resetmsg = 'RBARVAR'
           ! print *, resetmsg
        end if


     END IF


     IF (OK) THEN ! move forward


        call varianceDraw(pibarvar, pibarvarT, pibarvarDof, xshock(ndxPIbar,:), T, VSLstream)
        call varianceDraw(pinoisevar, pinoisevarT, pinoisevarDof, xshock(ndxPInoise,:), T, VSLstream)

        ! gapinno =  transpose(xshock(ndxGapStart:ndxGapStop,:))
        call vcvcholDrawTR(gapVCVchol, gapvcvT, gapvcvDof, gapshock, T, Ngap, VSLstream)


        ! ---------------------------------------------------------------------------
        ! PREPARE NEXT ITERATION
        ! ---------------------------------------------------------------------------

        ! a) store Draws after Burnin
        IF (j > BURNIN) THEN

           !  WRITE (*,*) 'STORING THISDRAW ', thisdraw

           DRAWstates(1,:,thisdraw)         = rr        
           DRAWstates(2,:,thisdraw)         = x(ndxPIbar,:)
           DRAWstates(3,:,thisdraw)         = x(ndxRbar,:)
           forall (i=1:Nyield) DRAWstates(3+i,:,thisdraw)         = x(ndxLONGRbar-1+i,:)
           DRAWstates(3+Nyield+1,:,thisdraw)         = x(ndxPIgap,:)
           DRAWstates(3+Nyield+2,:,thisdraw)         = x(ndxUgap,:)
           DRAWstates(3+Nyield+3,:,thisdraw)         = x(ndxINTgap,:)
           forall (i = 0 : Nyield - 1) DRAWstates(3+Nyield+4+i,:,thisdraw)  = x(ndxLONGINTgap+i,:)
           DRAWstates(6+2*Nyield+1,:,thisdraw)  = x(ndxPInoise,:)
           DRAWstates(6+2*Nyield+2,:,thisdraw) = istar

           DRAWf(:,thisdraw)           = f

           call vech(DRAWgapvcvchol(:,thisdraw), gapvcvchol)

           DRAWmaxlambda(:,thisdraw)   = maxlambda
           DRAWrbarvar(:,thisdraw)     = rbarvar
           DRAWpibarvar(:,thisdraw)    = pibarvar
           DRAWpinoisevar(:,thisdraw)    = pinoisevar
           forall (i=1:Nyield) DRAWavgtermpremia(i,thisdraw) = x(ndxLONGRbar+i-1,0) - x(ndxRbar,0) 

           if (doPDF) then

              ! predictive density simulated at end of sample

              ! update BB with rbarvar draw (note: X is on top of expanded state vector, ndx* variables still work
              BB(1:Nx,:)     = B
              AA(1:Nx,1:Nx)  = A(:,:,T)

              ! update (extended) state vector
              xx(1:Nx)                = x(:,T)
              forall (i=1:3) xx(Nx+i) = x(ndxPIbar,T-i) + x(ndxPIgap,T-i) + x(ndxPInoise,T-i) 

              call predictiveDensity(DRAWy(:,:,:,thisdraw), Nforecastdraws, maxhorizons, NNyy, NNxx, Nw, xx, AA, BB, CC, VSLstream)

              ! truncation 
              forall (i=1:maxhorizons,k=1:Nforecastdraws)
                 where (ytruncated .and. DRAWy(:,i,k,thisdraw) < ytrunclb)  DRAWy(:,i,k,thisdraw) = ytrunclb
              end forall
           end if

           joflastdraw = j
           thisdraw    = thisdraw + 1

        END IF ! J > BURNIN

        ! b) update stack
        lastInStack = minloc(stackRegister,1) ! find a free element on the stack

        stackRegister(lastInStack) = j + 1 ! notice the +1

        PREV_RBARVAR(lastInStack)       = rbarvar
        PREV_PIBARVAR(lastInStack)      = pibarvar
        PREV_PINOISEVAR(lastInStack)    = pinoisevar

        PREV_F(:,lastInStack)           = f

        PREV_GAPVCVCHOL(:,:,lastInStack)           = gapvcvchol

        ! WRITE (*,'("Stream ", i2, " at step ", i5, " updated lastInStack to ", i5)') timer%rank, j, lastInStack


        j = j + 1



     ELSE ! NOT(OK): shake or move back

        OK = .TRUE. ! a little superfluous, but good for the sake of clarity

        rejectionCount = rejectionCount + 1

        IF (rejectionCount > maxRejections) THEN
           j = 1
        ELSE IF (shakes < maxshakes) THEN
           shakes = shakes + 1  ! WRITE (*,'("Stream ", i2, ": shaking at step ", i5)') timer%rank, j
        ELSE ! move back
           shakes = 1
           IF (j > 1) THEN
              ! WRITE (*,'("Stream ", i2, ": moving back at step ", i5, " b/o ", a30)') timer%rank, j, resetmsg
              stackRegister(lastInStack) = -1
              lastInStack = maxloc(stackRegister,1)
              ! WRITE(*,*) "stackRegister=", stackRegister(lastInStack), 'j=', j

              if ((thisdraw > 1) .and. (j == joflastdraw)) then
                 WRITE (*,'("Stream ", i2, ": moving back at thisdraw ", i5)') timer%rank, thisdraw
                 thisdraw = thisdraw - 1
              end if

              j = j - 1
              if (stackRegister(lastInStack) < 1) then
                 j = 1
              else
                 if (stackRegister(lastInStack) .ne. j) then
                    print *, 'stack problem', ' j=', j, ' stackregister=', stackregister(lastinstack)
                 end if
              end if

           END IF ! j > 1

        END IF ! shakes 

     END IF ! OK


     ! Report Progress
     progresscomment = 'RC = ' // trim(int2str(rejectioncount))
     if (j > BURNIN) then
        sharedone = dble(j - Burnin) / dble(Nsim)
     else
        progresscomment = 'Burnin, ' // trim(progresscomment)
        sharedone = dble(j) / dble(BURNIN)
     end if
     call progressbarcomment(sharedone, timer, trim(progresscomment))

  END DO ! while thisdraw < Nsim

  call hrulefill
  WRITE (*, '(" STREAM ", i2, " IS DONE [reset count = ", i4, ", rejection count = ", i8, ", nominalrate trend ELB rejections = ", i8, ", Ndraws =  ", i8, "]")')  timer%rank, stackResetCount, rejectionCount, nominaltrendELBcount, Nsim + Burnin
  call hrulefill


END SUBROUTINE thissampler
