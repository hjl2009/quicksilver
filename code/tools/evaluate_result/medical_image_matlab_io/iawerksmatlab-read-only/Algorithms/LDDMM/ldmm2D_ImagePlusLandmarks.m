%
% Ihat is at time T
% input images are at time 0
%

%
% output switches
%
writeDebugImages = false;
writeDebugPoints = false;
writeImages = false;
writePoints = false;
dispMinMaxL2 = false;
extraOutput = false;
displayPlotOverview = true;

writeDebugEverything = false;
if writeDebugEverything
  writeDebugImages = true;
  writeDebugPoints = true;
  writeImages = true;
  writePoints = true;
  dispMinMaxL2 = true;
  extraOutput = true;
  displayPlotOverview = true;
end

% the data type used for storage and computation
% use 'single' for 32-bit floating point
% use 'double' for 64-bit floating point
dtype = 'single';

% the number of LDMM (outer) iterations
maxIter = 50; % 50
% the number of input images
M = 9; % 4
% the number of timesteps (i.e. velocity fields)
N = 8; % 10
% the number of dimensions for the image (2 or 3)
d = 2;
% the extent of the image (number of pixels on a side)
% NB: the image should be a cube, and it's best if s is a power of 2
s = 128; % 128
% the minimum and maximum number of feature points per image
% the final number of points per image will be in [min, max]
minmaxpts = [32 32]; % [16 16]
% standard deviation of random noise applied to the point positions
ptNoiseSigma = 0.0; % 0.1
% standard deviation of random noise applied to image
imageNoiseSigma = 0.05; % 0.05
% standard deviation of smoothing kernel applied to image
imageSmoothingSigma = 1.0; % 1

% sigma weights the smoothed velocity field in the gradient energy computation  
% increasing sigma will decrease the relative weight of the new velocity
% field
% NB: don't use the actual word 'sigma' because it is a built in matlab
% function 
sigma_image  = 0.06; % 0.06
sigma_points = 100000; % 0.04

% weight the distance measure between points for point matching (this is
% the sigma used in the point set metric)
sigma_ptmatch = 10;

% epsilon weights the gradient energy in the velocity update equation 
% eps=0.5 means replace current velocity with Linvb
% eps=0 means v stays the same
% initial development with 0.001
epsilon(1)  = 0.01;

% alpha, beta, and gamma determine the smoothing of the velocity fields
operatorType='laplace';
alpha = 0.5;
beta = 0;
gamma = 1;

alpha_pts = 10;
beta_pts = 0;
gamma_pts = 1;

%
% load images and point sets
%
fprintf('Loading images...');
t = cputime;
I = zeros([s s M],dtype);
for m=1:M
  fprintf('%d',m);
  radius = s*(m/M+1)/8;
%  I(:,:,m)            = makeTestImage([s s],...
%    'sphere',[radius imageNoiseSigma imageSmoothingSigma],dtype);
  I(:,:,m)            = makeTestImage([s s],...
    'bull',[imageNoiseSigma imageSmoothingSigma],dtype);
  [P{m}, PWeights{m}] = makeTestPoints([s s],'sphere',...
    [radius ptNoiseSigma],minmaxpts,dtype);
  %I(:,:,m) = makeTestImage([s s],'sphere',s*(rand+1)/8,dtype);
end
fprintf(' DONE (%g sec)\n',cputime-t);
if writeImages
  % write original images
  for q = 1:M
    writeMETA(squeeze(I(:,:,q)),sprintf('debug/input_image_%d.mhd',q));
  end
end
if writePoints
  % write original points
  for q = 1:M
    writeMETALandmark([P{q}; PWeights{q}],...
      sprintf('debug/input_pts_%d.mhd',q));
  end
end

%
% compute initial average image
%
J0T = I;
t = cputime;
fprintf('Computing initial average image...');
Ihat = mean(J0T,ndims(I));
Ihat0 = Ihat;
fprintf(' DONE (%g sec)\n',cputime-t);
% write initial average image
if writeImages
  writeMETA(Ihat,'debug/Ihat_k0.mhd');
end
fprintf('Computing initial variance...');
t = cputime;
Ivar = var(J0T,0,ndims(I));
Ivar0 = Ivar;
avar(1) = sum(Ivar(:));
fprintf(' DONE (%g sec)\n',cputime-t);
fprintf(' === Sum of voxelwise variance %g ::: %g%% === \n',avar(1),100*avar(1)/avar(1));
% write initial variance image
if writeImages
  writeMETA(Ivar,'debug/Ihat_ptwise_variance_k0.mhd');
end

% initial points average (in this case the union of the points). normalize
% weights.
JP0T = P;
t = cputime;
fprintf('Computing initial average points...');
IhatP = cell2mat(JP0T);
IhatP0 = IhatP;
IhatPWeights = cell2mat(PWeights);
IhatPWeights = IhatPWeights / sum(IhatPWeights(:));
fprintf(' DONE (%g sec)\n',cputime-t);
if writePoints
  % write initial points average
  writeMETALandmark([IhatP; IhatPWeights],sprintf('debug/IhatP_k0.mhd'));
end

%
% display initial image set
%
if displayPlotOverview
  figHandle_Overview = figure;
  figHandle_Mean = figure;
  figHandle_InitialSample = figure;
  figHandles = [figHandle_Overview figHandle_Mean figHandle_InitialSample];
  vizLDMMState(figHandles,...
    J0T, Ihat0, Ihat, Ivar0, Ivar, JP0T, IhatP0, IhatP, avar, epsilon, maxIter);
end

%
% initialize memory 
%
t = cputime;
fprintf('Allocating memory for image matching: ');
fprintf('v');
v = zeros([d s s N M],dtype);
%%%%%%%%%  V,X,Y,t,m  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
% V:  the element of the vector (x or y)
% X, Y: the x and y position of the voxel
% t: the time point
% m: the input image index
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% image data
% deformed image from time T to each time t
fprintf(',JTt');
JTt    = zeros([s s N],dtype);
% det of Jacobian of h-field mapping \Omega at t to T
fprintf(',dPhitT');
dPhitT = zeros([s s N],dtype);
% deformed image from time 0 to each time t
fprintf(',J0t');
J0t    = zeros([s s N+1],dtype);
% (spatial) gradient of J0t images
fprintf(',gJ0t');
gJ0t   = zeros([d s s N+1],dtype); 
% body force
fprintf(',b');
b      = zeros([d s s N],dtype); 
% regularized body force
fprintf(',Linvb');
Linvb  = zeros([d s s N],dtype); 
% gradient energy term from images
fprintf(',gE');
gE     = zeros([d s s N],dtype); 
fprintf(' DONE (%g sec)\n',cputime-t);
memUsageImage = ...
  whos('I','J0T','Ihat','v','JTt','dPhitT','J0t','gJ0t','b','Linvb','gE');
memUsageImageBytes = 0;
for i=1:length(memUsageImage)
  memUsageImageBytes = memUsageImageBytes + memUsageImage(i).bytes;
end

% landmark data
t = cputime;
fprintf('Allocating memory for point matching: ');
% points deformed from time 0 to each time t
fprintf('JP0t');
JP0t          = zeros([d minmaxpts(2) N+1],dtype);
% velocity field implied by pairwise differences between this pt set and
% the average point set
fprintf(',vIhatPJPDiffs');
bIhatPJPDiffs = zeros([d s s N],dtype);
vIhatPJPDiffs = zeros([d s s N],dtype);
% velocity field implied by pairwise differences between this pt set and
% itself
fprintf(',vJPJPDiffs');
bJPJPDiffs    = zeros([d s s N],dtype);
vJPJPDiffs    = zeros([d s s N],dtype);
% gradient energy term from point sets
fprintf(',gEP');
gEP           = zeros([d s s N],dtype);
fprintf(' DONE (%g sec)\n',cputime-t);
memUsagePts = ...
  whos('P','JP0T','IhatP','JP0t','vIhatPJPDiffs','vJPJPDiffs','gEP');
memUsagePtsBytes = 0;
for i=1:length(memUsagePts)
  memUsagePtsBytes = memUsagePtsBytes + memUsagePts(i).bytes;
end
fprintf('Memory usage: (image %d), (points %d), (total %d = %0.2f MB)\n',...
  memUsageImageBytes, memUsagePtsBytes,...
  memUsageImageBytes+memUsagePtsBytes,...
  (memUsageImageBytes+memUsagePtsBytes)/10^6); 

input('Press enter to begin matching...');

startTime = cputime;
for k=1:maxIter
  if k > 1 && any(diff(avar(end-M:end)) > 0)
    diff(avar(end-M:end))
    epsilon = [epsilon epsilon(end)/2];
  else
    epsilon = [epsilon epsilon(end)];
  end
  
  if sigma_ptmatch > 2
    sigma_ptmatch = sigma_ptmatch * 2 / 3;
  end
  for m=1:M
    iterStartTime = cputime;

    fprintf('================== iter: %d, image: %d, elapsed time: %g ================== \n',...
	    k,m,cputime-startTime);
    
    %
    % First address image match term
    %
    fprintf('Image matching...\n');
    
    %
    % compute JTt (image (Ihat) at T deformed to each timepoint t)
    % and dPhitT (det jacobian of phi_t, the hfield from t to T)
    %
    t = cputime;
    fprintf('Computing (backward, T-->t) def. images & det. Jacobians...');
    [JTt, dPhitT] = computeJTt(Ihat, v(:,:,:,:,m)); 
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugImages
      % write debug images
      for q = 1:N
        writeMETA(squeeze(JTt(:,:,q)),sprintf('debug/JTt_k%d_m%d_t%d.mhd',k,m,q));
        writeMETA(squeeze(dPhitT(:,:,q)),sprintf('debug/dPhitT_k%d_m%d_t%d.mhd',k,m,q));
      end
    end

    %
    % compute J0t (image at 0 deformed to each timepoint t)
    % 
    t = cputime;
    fprintf('Computing (forward, 0-->t) deformed images...');
    J0t = computeJ0t(I(:,:,m), v(:,:,:,:,m)); 
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugImages
      % write debug images
      for q = 1:N+1
        writeMETA(squeeze(J0t(:,:,q)),sprintf('debug/J0t_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    %
    % compute gJ0t (gradient of each deformed (0->t) image)
    %
    t = cputime;
    fprintf('Computing gradients of (forward) deformed images...');
    gJ0t = computeImageGradients(J0t);
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugImages
      % write debug images
      for q = 1:N+1
        writeMETA(squeeze(gJ0t(:,:,:,q)),sprintf('debug/gJ0t_k%d_m%d_t%d.mhd',k,m,q));
      end
    end

    %
    % compute "body force" b = dPhitT*(J0t-JTt) * gJ0t at each time step
    %
    t = cputime;
    fprintf('Computing body force...');    
    b(1,:,:,:) = dPhitT.*(J0t(:,:,1:N)-JTt) .* squeeze(gJ0t(1,:,:,1:N));
    b(2,:,:,:) = dPhitT.*(J0t(:,:,1:N)-JTt) .* squeeze(gJ0t(2,:,:,1:N));
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(b(:))));
      fprintf('MAX = %g\n',max(b(:)));
      fprintf('MIN = %g\n',min(b(:)));
    end
    if writeDebugImages
      % write debug images
      for q = 1:N
        writeMETA(squeeze(b(:,:,:,q)),sprintf('debug/b_k%d_m%d_t%d.mhd',k,m,q));
      end
    end

    %
    % apply Greens function to regularize b
    %
    t = cputime;
    fprintf('Applying Green''s function...');
    for tm = 1:size(b,ndims(b))
      fprintf('%d',tm);
      Linvb(:,:,:,tm) = greensFunction(squeeze(b(:,:,:,tm)),...
					 operatorType,[alpha beta gamma]); 
    end
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(Linvb(:))));
      fprintf('MAX = %g\n',max(Linvb(:)));
      fprintf('MIN = %g\n',min(Linvb(:)));
    end
    if writeDebugImages
      % write debug images
      for q = 1:N
        writeMETA(squeeze(Linvb(:,:,:,q)),sprintf('debug/Linvb_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    % zero boundary condition
    Linvb(:,[1 end],:,:) = 0;
    Linvb(:,:,[1 end],:) = 0;

    %
    % compute gradient energy term gE = - 2/sigma^2 * Linvb
    %
    t = cputime;
    fprintf('Computing gradient energy...');
    gE = -(2/sigma_image^2)*Linvb;
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(gE(:))));
      fprintf('MAX = %g\n',max(gE(:)));
      fprintf('MIN = %g\n',min(gE(:)));
    end
    if writeDebugImages
      for q = 1:N
        writeMETA(squeeze(gE(:,:,:,q)),sprintf('debug/gE_k%d_m%d_t%d.mhd',k,m,q));
      end
    end

    %
    %
    % now compute velocity field that will minimize energy based on point
    % sets
    %
    %
    if ~bypassPoints
    fprintf('Pointset matching...\n');
    
    %
    % deform image points from time 0 to each time point t according to the
    % current deformation
    %
    t = cputime;
    fprintf('Computing (forward, 0-->t) deformed points...');
    JP0t = computeJP0t(P{m}, v(:,:,:,:,m));
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugPoints
      for q = 1:N+1
        writeMETA(squeeze(J0t(:,:,q)),sprintf('debug/J0t_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    %
    % compute the gradient energy term related to weighted, pairwise
    % differences between Ihat landmarks and these landmarks at time T.
    % The differences are pulled back to each time point t and a velocity
    % field is generated via the green's function.
    %
    t = cputime;
    fprintf('Computing pairwise difference field IhatP-JP...');
    bIhatPJPDiffs = computePairwiseWeightedDifferencesField(IhatP,...
      JP0t, v(:,:,:,:,m), sigma_ptmatch);
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugPoints
      for q = 1:N
        writeMETA(squeeze(bIhatPJPDiffs(:,:,:,q)),...
          sprintf('debug/bIhatJP_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    %
    % only need to do this once since everything is linear
    %
    
    t = cputime;
    fprintf('Applying Green''s function...');
    for tm = 1:size(bIhatPJPDiffs,ndims(vIhatPJPDiffs))
      fprintf('%d',tm);
      vIhatPJPDiffs(:,:,:,tm) = greensFunction(squeeze(bIhatPJPDiffs(:,:,:,tm)),...
					 operatorType,[alpha_pts beta_pts gamma_pts]); 
    end
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(vIhatPJPDiffs(:))));
      fprintf('MAX = %g\n',max(vIhatPJPDiffs(:)));
      fprintf('MIN = %g\n',min(vIhatPJPDiffs(:)));
    end
    if writeDebugPoints
      % write debug images
      for q = 1:N
        writeMETA(squeeze(vIhatPJPDiffs(:,:,:,q)),sprintf('debug/vIhatJP_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    % zero boundary condition
    vIhatPJPDiffs(:,[1 end],:,:) = 0;
    vIhatPJPDiffs(:,:,[1 end],:) = 0;
   
    %
    % compute the gradient energy term related to weighted, pairwise
    % differences between these landmarks at time T. The differences are
    % pulled back to each time point t and a velocity field is generated
    % via the green's function. 
    %
    t = cputime;
    fprintf('Computing pairwise difference field JP-JP...');
    bJPJPDiffs = computePairwiseWeightedDifferencesField(JP0t(:,:,end),...
      JP0t, v(:,:,:,:,m), sigma_ptmatch);
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugPoints
      for q = 1:N
        writeMETA(squeeze(bIhatPJPDiffs(:,:,:,q)),...
          sprintf('debug/bJPJP_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    t = cputime;
    fprintf('Applying Green''s function...');
    for tm = 1:size(bJPJPDiffs,ndims(bJPJPDiffs))
      fprintf('%d',tm);
      vJPJPDiffs(:,:,:,tm) = ...
        greensFunction(squeeze(bJPJPDiffs(:,:,:,tm)),...
        operatorType,[alpha_pts beta_pts gamma_pts]);
    end
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(vJPJPDiffs(:))));
      fprintf('MAX = %g\n',max(vJPJPDiffs(:)));
      fprintf('MIN = %g\n',min(vJPJPDiffs(:)));
    end
    if writeDebugPoints
      % write debug images
      for q = 1:N
        writeMETA(squeeze(vJPJPDiffs(:,:,:,q)),sprintf('debug/vJPJP_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    % zero boundary condition
    vJPJPDiffs(:,[1 end],:,:) = 0;
    vJPJPDiffs(:,:,[1 end],:) = 0;    
    
    %
    % compute the gradient energy 
    %
    t = cputime;
    fprintf('Computing gradient energy...');    
    gEP = (2/sigma_points^2)*vJPJPDiffs-(2/sigma_points^2)*vIhatPJPDiffs;
    %gEP = (2/sigma_points^2)*vIhatPJPDiffs;
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(gEP(:))));
      fprintf('MAX = %g\n',max(gEP(:)));
      fprintf('MIN = %g\n',min(gEP(:)));
    end
    if writeDebugPoints
      for q = 1:N
        writeMETA(squeeze(gEP(:,:,:,q)),sprintf('debug/gEP_k%d_m%d_t%d.mhd',k,m,q));
      end
    end
    
    %
    % update velocity fields v = v - epsilon_i * gE_i - epsilon_l * gE_l
    %
    t = cputime;
    fprintf('Updating velocity fields...');
    v(:,:,:,:,m) = v(:,:,:,:,m) - epsilon(end)*(2*v(:,:,:,:,m)+gE+gEP);
    fprintf(' DONE (%g sec)\n',cputime-t);
    if dispMinMaxL2
      fprintf('NUM NAN = %g\n',sum(isnan(v(:))));
      fprintf('MAX = %g\n',max(v(:)));
      fprintf('MIN = %g\n',min(v(:)));
    end
    if writeDebugImages    
      for q = 1:N
        writeMETA(squeeze(v(:,:,:,q)),sprintf('debug/v_k%d_m%d_t%d.mhd',k,m,q));
      end
    end

    %
    % update Ihat: need to compute J0T for this image
    %
    t = cputime;
    fprintf('Updating average image...');
    J0t = computeJ0t(I(:,:,m), v(:,:,:,:,m)); 
    J0T(:,:,m) = J0t(:,:,N+1);
    Ihat = mean(J0T,ndims(I));    
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugImages
      writeMETA(Ihat,sprintf('debug/Ihat_k%d_m%d.mhd',k,m));
    end
    
    %
    % update Ihatp: need to redeform points for this image
    %
    JP0t = computeJP0t(P{m}, v(:,:,:,:,m));    
    JP0T{m} = JP0t(:,:,N+1);
    IhatP = cell2mat(JP0T);
    if writePoints
      % write initial points average
      writeMETALandmark([IhatP; IhatPWeights],sprintf('debug/IhatP_k%d_m%d.mhd',k,m));
    end
    
    %
    % update convergence measure (TODO: add landmarks convergence measure)
    %
    t = cputime;
    fprintf('Computing variance...');
    Ivar = var(J0T,0,ndims(I));
    avar(M*(k-1) + m + 1) = sum(Ivar(:));
    fprintf(' DONE (%g sec)\n',cputime-t);
    if writeDebugImages
      writeMETA(Ivar,sprintf('debug/Ihat_ptwise_variance_k%d_m%d.mhd',k,m));
    end
    
    fprintf('::::::::::::::: Sum of voxelwise variance %g ::: %g%% :::::::::::::::\n',...
	    avar(M*(k-1) + m + 1),...
	    100*avar(M*(k-1) + m + 1)/avar(1));
    fprintf('Iteration Time: %g\n',cputime-iterStartTime);
    
    if displayPlotOverview
      vizLDMMState(figHandles,...
        J0T, Ihat0, Ihat, Ivar0, Ivar, JP0T, IhatP0, IhatP,...
        avar, epsilon,maxIter);
    end
    
    %input('Press enter to continue...');
  end
  
  % write images at end of iteration
  if writeImages
    writeMETA(Ihat,sprintf('debug/Ihat_k%d.mhd',k));
  end
  if writeImages
    writeMETA(Ivar,sprintf('debug/Ihat_ptwise_variance_k%d.mhd',k));
  end
end
fprintf('Total Time: %g (sec)\n',cputime-startTime);
fprintf('%0.3g, \n',avar/avar(1));
