function [X,  output] = FISTA_REC(params)

% <<<< FISTA-based reconstruction routine using ASTRA-toolbox >>>>

% This code solves regularised LS/PWLS problem using FISTA approach [1] and its
% modifications (Group-Huber FISTA and Students't FISTA) [2,3]. The
% ordered-subset version is provided and various projection geometries
% supported. This code depends on CCPi-Regularisation toolbox.

% <DISCLAIMER>
% It is recommended to use ASTRA version 1.8 or later in order to avoid
% crashing due to GPU memory overflow for big datasets. Regularisers on GPU
% can also crash if large 3D volumes provided.

% <License>
% GPLv3 license (ASTRA toolbox)

% ___Input___:
% params.[] file:
%----------------General Parameters------------------------
%       - .proj_geom (geometry of the projector) [required]
%       - .vol_geom (geometry of the reconstructed object) [required]
%       - .sino (2D or 3D sinogram) [required]
%       - .iterFISTA (iterations for the main FISTA loop, default 40)
%       - .L_const (Lipschitz constant, default Power method to automatically estimate it)
%       - .phantomExact (ideal phantom if available)
%       - .weights (statisitcal weights for the PWLS model, same dimension as sinogram)
%       - .fidelity (if one needs 'students_data' fidelity [3])
%       - .ROI (Region-of-interest, only if phantomExact is given)
%       - .initialize (a 'warm start' using SIRT method from ASTRA)
%------------Ring removal or Group-Huber fidelity----------
%       - .Ring_LambdaR_L1 (regularization parameter for L1-ring minimization, if lambdaR_L1 > 0 then GH switched on, default off)
%       - .Ring_Alpha (larger values (~20) can accelerate convergence but check stability, default 1)
%-------------Regularisation (main parameters)------------------
%       - .Regul_device (select 'cpu' or 'gpu' device, 'cpu' is default)
%       - .Regul_tol (tolerance to terminate regul iterations, default 0.0, stopping based on iterations)
%       - .Regul_Iterations (iterations for the selected penalty, default 25)
%       - .Regul_time_step (some penalties require time marching parameter, default 0.01)
%       - .Regul_Dimension ('2D' or '3D' way to apply regularisation, '2D' is the default)
%-------------Regularisation choices------------------
%       1 .Regul_Lambda_ROFTV (ROF-TV regularisation parameter)
%       2 .Regul_Lambda_FGPTV (FGP-TV regularisation parameter)
%       3 .Regul_Lambda_SBTV (SplitBregman-TV regularisation parameter)
%       4 .Regul_Lambda_Diffusion (Nonlinear diffusion regularisation parameter)
%       5 .Regul_Lambda_AnisDiff4th (Anisotropic diffusion of higher order regularisation parameter)
%       ... more to be added

%----------------Visualization parameters------------------------
%       - .show (visualize reconstruction 1/0, (0 default))
%       - .maxvalplot (maximum value to use for imshow[0 maxvalplot])
%       - .slice (for 3D volumes - slice number to imshow)
% ___Output___:
% 1. X - reconstructed image/volume
% 2. output - a structure with
%    - .Resid_error - residual error (if phantomExact is given)
%    - .objective: value of the objective function
%    - .L_const: Lipshitz constant to avoid recalculations

% References:
% 1. "A Fast Iterative Shrinkage-Thresholding Algorithm for Linear Inverse
% Problems" by A. Beck and M Teboulle
% 2. "Ring artifacts correction in compressed sensing..." by P. Paleo
% 3. "A novel tomographic reconstruction method based on the robust
% Student's t function for suppressing data outliers" D. Kazantsev et.al.

% Dealing with input parameters
if (isfield(params,'proj_geom') == 0)
    error('%s \n', 'Please provide ASTRA projection geometry - proj_geom');
else
    proj_geom = params.proj_geom;
end
if (isfield(params,'vol_geom') == 0)
    error('%s \n', 'Please provide ASTRA object geometry - vol_geom');
else
    vol_geom = params.vol_geom;
end
N = params.vol_geom.GridColCount;
if (isfield(params,'sino'))
    sino = params.sino;
    [Detectors, anglesNumb, SlicesZ] = size(sino);
    fprintf('%s %i %s %i %s %i %s \n', 'Sinogram has a dimension of', Detectors, 'detectors;', anglesNumb, 'projections;', SlicesZ, 'vertical slices.');
else
    error('%s \n', 'Please provide a sinogram');
end
if (isfield(params,'iterFISTA'))
    iterFISTA = params.iterFISTA;
else
    iterFISTA = 40;
end
if (isfield(params,'weights'))
    weights = params.weights;
else
    weights = ones(size(sino));
end
if (isfield(params,'fidelity'))
    students_data = 0;
    if (strcmp(params.fidelity,'students_data') == 1)
        students_data = 1;
    end
else
    students_data = 0;
end
if (isfield(params,'L_const'))
    L_const = params.L_const;
else
    % using Power method (PM) to establish L (Lipshitz) constant
    fprintf('%s %s %s \n', 'Calculating Lipshitz constant for',proj_geom.type, 'beam geometry...');
    if (strcmp(proj_geom.type,'parallel') || strcmp(proj_geom.type,'fanflat') || strcmp(proj_geom.type,'fanflat_vec'))
        % for 2D geometry we can do just one selected slice
        niter = 15; % number of iteration for the PM
        x1 = rand(N,N,1);
        sqweight = sqrt(weights(:,:,1));
        [sino_id, y] = astra_create_sino_cuda(x1, proj_geom, vol_geom);
        y = sqweight.*y';
        astra_mex_data2d('delete', sino_id);
        for i = 1:niter
            [x1] = astra_create_backprojection_cuda((sqweight.*y)', proj_geom, vol_geom);
            s = norm(x1(:));
            x1 = x1./s;
            [sino_id, y] = astra_create_sino_cuda(x1, proj_geom, vol_geom);
            y = sqweight.*y';
            astra_mex_data2d('delete', sino_id);
        end
    elseif (strcmp(proj_geom.type,'cone') || strcmp(proj_geom.type,'parallel3d') || strcmp(proj_geom.type,'parallel3d_vec') || strcmp(proj_geom.type,'cone_vec'))
        % 3D geometry
        niter = 8; % number of iteration for PM
        x1 = rand(N,N,SlicesZ);
        sqweight = sqrt(weights);
        [sino_id, y] = astra_create_sino3d_cuda(x1, proj_geom, vol_geom);
        y = sqweight.*y;
        astra_mex_data3d('delete', sino_id);
        
        for i = 1:niter
            [id,x1] = astra_create_backprojection3d_cuda(sqweight.*y, proj_geom, vol_geom);
            s = norm(x1(:));
            x1 = x1/s;
            [sino_id, y] = astra_create_sino3d_cuda(x1, proj_geom, vol_geom);
            y = sqweight.*y;
            astra_mex_data3d('delete', sino_id);
            astra_mex_data3d('delete', id);
        end
        clear x1
    else
        error('%s \n', 'No suitable geometry has been found!');
    end
    L_const = s;
end
if (L_const ~= 0)
    L_const_inv = 1.0/L_const;
else
    error('Lipshitz constant cannot be zero')
end
if (isfield(params,'phantomExact'))
    phantomExact = params.phantomExact;
else
    phantomExact = 'none';
end
if (isfield(params,'ROI'))
    ROI = params.ROI;
else
    ROI = find(phantomExact>=0.0);
end

% <<<<< GH-fidelity >>>>>
if (isfield(params,'Ring_LambdaR_L1'))
    lambdaR_L1 = params.Ring_LambdaR_L1;
else
    lambdaR_L1 = 0;
end
if (isfield(params,'Ring_Alpha'))
    alpha_ring = params.Ring_Alpha; % higher values can accelerate ring removal procedure
else
    alpha_ring = 1;
end
%%%%%%%%%%%%%%%%%%%%%%%%%

% <<<<< Regularisation related >>>>>
if (isfield(params,'Regul_Dimension'))
    Dimension = params.Regul_Dimension;
    if (strcmp('3D', Dimension) == 1)
        Dimension = '3D';
    end
else
    Dimension = '2D';
end
device = 0; % (cpu)
if (isfield(params,'Regul_device'))
    if (strcmp(params.Regul_device, 'gpu') == 1)
        device = 1; % (gpu)
    end
end
if (isfield(params,'Regul_tol'))
    tol = params.Regul_tol;
else
    tol = 0.0; % 1.0e-06
end
if (isfield(params,'Regul_Iterations'))
    IterationsRegul = params.Regul_Iterations;
else
    IterationsRegul = 25;
end
if (isfield(params,'Regul_time_step'))
    Regul_time_step = params.Regul_time_step;
else
    Regul_time_step = 0.01;
end
if (isfield(params,'Regul_sigmaEdge'))
    sigmaEdge = params.Regul_sigmaEdge;
else
    sigmaEdge = 0.01; % edge-preserving parameter
end
if (isfield(params,'Regul_Lambda_ROFTV'))
    lambdaROF_TV = params.Regul_Lambda_ROFTV;
    fprintf('\n %s\n', 'ROF-TV regularisation is enabled...');
else
    lambdaROF_TV = 0;
end
if (isfield(params,'Regul_Lambda_FGPTV'))
    lambdaFGP_TV = params.Regul_Lambda_FGPTV;
    fprintf('\n %s\n', 'FGP-TV regularisation is enabled...');
else
    lambdaFGP_TV = 0;
end
if (isfield(params,'Regul_Lambda_SBTV'))
    lambdaSB_TV = params.Regul_Lambda_SBTV;
    fprintf('\n %s\n', 'SB-TV regularisation is enabled...');
else
    lambdaSB_TV = 0;
end
if (isfield(params,'Regul_Lambda_Diffusion'))
    lambdaDiffusion = params.Regul_Lambda_Diffusion;
    fprintf('\n %s\n', 'Nonlinear diffusion regularisation is enabled...');
else
    lambdaDiffusion = 0;
end
if (isfield(params,'Regul_FuncDiff_Type'))
    FuncDiff_Type = params.Regul_FuncDiff_Type;
    if ((strcmp(FuncDiff_Type, 'Huber') ~= 1) && (strcmp(FuncDiff_Type, 'PM') ~= 1) && (strcmp(FuncDiff_Type, 'Tukey') ~= 1))
        error('Please select appropriate FuncDiff_Type - Huber, PM or Tukey')
    end
end
if (isfield(params,'Regul_Lambda_AnisDiff4th'))
    lambdaDiffusion4th = params.Regul_Lambda_AnisDiff4th;
    fprintf('\n %s\n', 'Regularisation with anisotropic diffusion of 4th order is enabled...');
else
    lambdaDiffusion4th = 0;
end
if (isfield(params,'Regul_Lambda_TGV'))
    lambdaTGV = params.Regul_Lambda_TGV;
    
    if (isfield(params,'Regul_TGV_alpha0'))
        alpha0 = params.Regul_TGV_alpha0;
    else
        alpha0 = 1.0;
    end
    if (isfield(params,'Regul_TGV_alpha1'))
        alpha1 = params.Regul_TGV_alpha1;
    else
        alpha1 = 2.0;
    end
    fprintf('\n %s\n', 'Total Generilised Variation (TGV) regularisation is enabled...');
else
    lambdaTGV = 0;
end
%%%%%%%%%%%%%%%%%%%%%%%%%
if (isfield(params,'show'))
    show = params.show;
else
    show = 0;
end
if (isfield(params,'maxvalplot'))
    maxvalplot = params.maxvalplot;
else
    maxvalplot = 1;
end
if (isfield(params,'slice'))
    slice = params.slice;
else
    slice = 1;
end
if (isfield(params,'initialize'))
    X  = params.initialize;
    if ((size(X,1) ~= N) || (size(X,2) ~= N) || (size(X,3) ~= SlicesZ))
        error('%s \n', 'The initialized volume has different dimensions!');
    end
else
    X = zeros(N,N,SlicesZ, 'single'); % storage for the solution
end
if (isfield(params,'subsets'))
    % Ordered Subsets reorganisation of data and angles
    subsets = params.subsets; % subsets number
    angles = proj_geom.ProjectionAngles;
    binEdges = linspace(min(angles),max(angles),subsets+1);
    
    % assign values to bins
    [binsDiscr,~] = histc(angles, [binEdges(1:end-1) Inf]);
    
    % get rearranged subset indices
    IndicesReorg = zeros(length(angles),1);
    counterM = 0;
    for ii = 1:max(binsDiscr(:))
        counter = 0;
        for jj = 1:subsets
            curr_index = ii+jj-1 + counter;
            if (binsDiscr(jj) >= ii)
                counterM = counterM + 1;
                IndicesReorg(counterM) = curr_index;
            end
            counter = (counter + binsDiscr(jj)) - 1;
        end
    end
else
    subsets = 0; % Classical FISTA
end

%----------------Reconstruction part------------------------
Resid_error = zeros(iterFISTA,1); % errors vector (if the ground truth is given)
objective = zeros(iterFISTA,1); % objective function values vector

if (subsets == 0)
    % Classical FISTA (no SUBSETS)
    t = 1;
    X_t = X;
    
    r = zeros(Detectors,SlicesZ, 'single'); % 2D array (for 3D data) of sparse "ring" vectors
    r_x = r; % another ring variable
    residual = zeros(size(sino),'single');
    
    % Outer FISTA iterations loop
    for i = 1:iterFISTA
        
        X_old = X;
        t_old = t;
        r_old = r;
        
        if (strcmp(proj_geom.type,'parallel') || strcmp(proj_geom.type,'fanflat') || strcmp(proj_geom.type,'fanflat_vec'))
            % if geometry is 2D use slice-by-slice projection-backprojection routine
            sino_updt = zeros(size(sino),'single');
            for kkk = 1:SlicesZ
                [sino_id, sinoT] = astra_create_sino_cuda(X_t(:,:,kkk), proj_geom, vol_geom);
                sino_updt(:,:,kkk) = sinoT';
                astra_mex_data2d('delete', sino_id);
            end
        else
            % for 3D geometry (watch the GPU memory overflow in earlier ASTRA versions < 1.8)
            [sino_id, sino_updt] = astra_create_sino3d_cuda(X_t, proj_geom, vol_geom);
            astra_mex_data3d('delete', sino_id);
        end
        % Data fidelities selection
        if (lambdaR_L1 > 0)
            % the ring removal part (Group-Huber fidelity)
            for kkk = 1:anglesNumb
                residual(:,kkk,:) =  squeeze(weights(:,kkk,:)).*(squeeze(sino_updt(:,kkk,:)) - (squeeze(sino(:,kkk,:)) - alpha_ring.*r_x));
            end
            vec = sum(residual,2);
            if (SlicesZ > 1)
                vec = squeeze(vec(:,1,:));
            end
            r = r_x - L_const_inv.*vec;
            objective(i) = (0.5*sum(residual(:).^2)); % for the objective function output
        elseif (students_data > 0)
            % artifacts removal with Students t penalty
            residual = weights.*(sino_updt - sino);
            for kkk = 1:SlicesZ
                res_vec = reshape(residual(:,:,kkk), Detectors*anglesNumb, 1); % 1D vectorized sinogram
                %s = 100;
                %gr = (2)*res_vec./(s*2 + conj(res_vec).*res_vec);
                [ff, gr] = studentst(res_vec, 1);
                residual(:,:,kkk) = reshape(gr, Detectors, anglesNumb);
            end
            objective(i) = ff; % for the objective function output
        else
            % no ring removal (LS model)
            residual = weights.*(sino_updt - sino);
            objective(i) = 0.5*norm(residual(:)); % for the objective function output
        end
        
        % if the geometry is 2D use slice-by-slice projection-backprojection routine
        if (strcmp(proj_geom.type,'parallel') || strcmp(proj_geom.type,'fanflat') || strcmp(proj_geom.type,'fanflat_vec'))
            x_temp = zeros(size(X),'single');
            for kkk = 1:SlicesZ
                [x_temp(:,:,kkk)] = astra_create_backprojection_cuda(squeeze(residual(:,:,kkk))', proj_geom, vol_geom);
            end
        else
            [id, x_temp] = astra_create_backprojection3d_cuda(residual, proj_geom, vol_geom);
            astra_mex_data3d('delete', id);
        end
        X = X_t - L_const_inv.*x_temp;
        
        %--------------Regularisation part (CCPi-RGLTK)---------------%
        if (lambdaROF_TV > 0)
            % ROF-TV regularisation is enabled
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        X(:,:,kkk) = ROF_TV(single(X(:,:,kkk)), lambdaROF_TV*L_const_inv, IterationsRegul, Regul_time_step, tol);
                    else
                        X(:,:,kkk) = ROF_TV_GPU(single(X(:,:,kkk)), lambdaROF_TV*L_const_inv, IterationsRegul, Regul_time_step, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = ROF_TV(X, lambdaROF_TV*L_const_inv, IterationsRegul, Regul_time_step, tol);
                else
                    % GPU
                    X = ROF_TV_GPU(X, lambdaROF_TV*L_const_inv, IterationsRegul, Regul_time_step, tol);
                end
            end
            f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaROF_TV*L_const_inv, 2)); % get TV energy value
            objective(i) = (objective(i) + f_valTV);
        end
        if (lambdaFGP_TV > 0)
            % FGP-TV regularisation is enabled
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        % CPU
                        X(:,:,kkk) = FGP_TV(X(:,:,kkk), lambdaFGP_TV*L_const_inv, IterationsRegul, tol);
                    else
                        % GPU
                        X(:,:,kkk) = FGP_TV_GPU(X(:,:,kkk), lambdaFGP_TV*L_const_inv, IterationsRegul, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = FGP_TV(X, lambdaFGP_TV*L_const_inv, IterationsRegul, tol);
                else
                    % GPU
                    X = FGP_TV_GPU(X, lambdaFGP_TV*L_const_inv, IterationsRegul, tol);
                end
            end
            f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaFGP_TV*L_const_inv, 2)); % get TV energy value
            objective(i) = (objective(i) + f_valTV);
        end
        if (lambdaSB_TV > 0)
            % Split Bregman regularisation is enabled
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        % CPU
                        X(:,:,kkk) = SB_TV(X(:,:,kkk), lambdaSB_TV*L_const_inv, IterationsRegul, tol);
                    else
                        % GPU
                        X(:,:,kkk) = SB_TV_GPU(X(:,:,kkk), lambdaSB_TV*L_const_inv, IterationsRegul, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = SB_TV(X, lambdaSB_TV*L_const_inv, IterationsRegul, tol);
                else
                    % GPU
                    X = SB_TV_GPU(X, lambdaSB_TV*L_const_inv, IterationsRegul, tol);
                end
            end
            f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaSB_TV*L_const_inv, 2)); % get TV energy value
            objective(i) = (objective(i) + f_valTV);
        end
        if (lambdaDiffusion > 0)
            % Nonlinear diffusion regularisation is enabled
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        % CPU
                        X(:,:,kkk) = NonlDiff(X(:,:,kkk), lambdaDiffusion*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, FuncDiff_Type, tol);
                    else
                        % GPU
                        X(:,:,kkk) = NonlDiff_GPU(X(:,:,kkk), lambdaDiffusion*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, FuncDiff_Type, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = NonlDiff(X, lambdaDiffusion*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, FuncDiff_Type, tol);
                else
                    % GPU
                    X = NonlDiff(X, lambdaDiffusion*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, FuncDiff_Type, tol);
                end
            end
            objective(i) = objective(i);
        end
        if (lambdaDiffusion4th > 0)
            % Anisotropic diffusion of 4th order regularisation is enabled
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        % CPU
                        X(:,:,kkk) = Diffusion_4thO(X(:,:,kkk), lambdaDiffusion4th*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, tol);
                    else
                        % GPU
                        X(:,:,kkk) = Diffusion_4thO_GPU(X(:,:,kkk), lambdaDiffusion4th*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = Diffusion_4thO(X, lambdaDiffusion4th*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, tol);
                else
                    % GPU
                    X = Diffusion_4thO_GPU(X, lambdaDiffusion4th*L_const_inv, sigmaEdge, IterationsRegul, Regul_time_step, tol);
                end
            end
            objective(i) = objective(i);
        end
        if (lambdaTGV > 0)
            % TGV
            if ((strcmp('2D', Dimension) == 1))
                % 2D regularisation
                for kkk = 1:SlicesZ
                    if (device == 0)
                        % CPU
                        X(:,:,kkk) = TGV(X(:,:,kkk), lambdaTGV*L_const_inv, alpha1, alpha0, IterationsRegul, 12.0, tol);
                    else
                        % GPU
                        X(:,:,kkk) = TGV_GPU(X(:,:,kkk), lambdaTGV*L_const_inv, alpha1, alpha0, IterationsRegul, 12.0, tol);
                    end
                end
            else
                % 3D regularisation
                if (device == 0)
                    % CPU
                    X = TGV(X, lambdaTGV*L_const_inv, alpha1, alpha0, IterationsRegul, 12.0, tol);
                else
                    % GPU
                    X = TGV_GPU(X, lambdaTGV*L_const_inv, alpha1, alpha0, IterationsRegul, 12.0, tol);
                end
            end
        end
        
        
        if (lambdaR_L1 > 0)
            r =  max(abs(r)-lambdaR_L1, 0).*sign(r); % soft-thresholding operator for ring vector
        end
        
        t = (1 + sqrt(1 + 4*t^2))/2; % updating t
        X_t = X + ((t_old-1)/t).*(X - X_old); % updating X
        
        if (lambdaR_L1 > 0)
            r_x = r + ((t_old-1)/t).*(r - r_old); % updating r
        end
        
        if (show == 1)
            figure(10); imshow(X(:,:,slice), [0 maxvalplot]);
            if (lambdaR_L1 > 0)
                figure(11); plot(r); title('Rings offset vector')
            end
            pause(0.01);
        end
        if (strcmp(phantomExact, 'none' ) == 0)
            Resid_error(i) = RMSE(X(ROI), phantomExact(ROI));
            fprintf('%s %i %s %s %.4f  %s %s %f \n', 'Iteration Number:', i, '|', 'Error RMSE:', Resid_error(i), '|', 'Objective:', objective(i));
        else
            fprintf('%s %i  %s %s %f \n', 'Iteration Number:', i, '|', 'Objective:', objective(i));
        end
    end
else
    % <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<OS FISTA>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    % <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<OS FISTA>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    % <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<OS FISTA>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>
    % Ordered Subsets (OS) FISTA reconstruction routine (normally one order of magnitude faster than the classical version)
    t = 1;
    X_t = X;
    proj_geomSUB = proj_geom;
    
    r = zeros(Detectors,SlicesZ, 'single'); % 2D array (for 3D data) of sparse "ring" vectors
    r_x = r; % another ring variable
    residual2 = zeros(size(sino),'single');
    sino_updt_FULL = zeros(size(sino),'single');
    
    
    % Outer FISTA iterations loop
    for i = 1:iterFISTA
        if ((i > 1) && (lambdaR_L1 > 0))
            % in order to make Group-Huber fidelity work with ordered subsets
            % we still need to work with full sinogram
            
            % the offset variable must be calculated for the whole
            % updated sinogram - sino_updt_FULL
            for kkk = 1:anglesNumb
                residual2(:,kkk,:) = squeeze(weights(:,kkk,:)).*(squeeze(sino_updt_FULL(:,kkk,:)) - (squeeze(sino(:,kkk,:)) - alpha_ring.*r_x));
            end
            
            r_old = r;
            vec = sum(residual2,2);
            if (SlicesZ > 1)
                vec = squeeze(vec(:,1,:));
            end
            r = r_x - L_const_inv.*vec; % update ring variable
        end
        % subsets loop
        counterInd = 1;
        for ss = 1:subsets
            X_old = X;
            t_old = t;
            
            numProjSub = binsDiscr(ss); % the number of projections per subset
            sino_updt_Sub = zeros(Detectors, numProjSub, SlicesZ,'single');
            CurrSubIndeces = IndicesReorg(counterInd:(counterInd + numProjSub - 1)); % extract indeces attached to the subset
            proj_geomSUB.ProjectionAngles = angles(CurrSubIndeces);
            
            if (strcmp(proj_geom.type,'parallel') || strcmp(proj_geom.type,'fanflat') || strcmp(proj_geom.type,'fanflat_vec'))
                % if geometry is 2D use slice-by-slice projection-backprojection routine
                for kkk = 1:SlicesZ
                    [sino_id, sinoT] = astra_create_sino_cuda(X_t(:,:,kkk), proj_geomSUB, vol_geom);
                    sino_updt_Sub(:,:,kkk) = sinoT';
                    astra_mex_data2d('delete', sino_id);
                end
            else
                % for 3D geometry (watch the GPU memory overflow in earlier ASTRA versions < 1.8)
                [sino_id, sino_updt_Sub] = astra_create_sino3d_cuda(X_t, proj_geomSUB, vol_geom);
                astra_mex_data3d('delete', sino_id);
            end
            
            if (lambdaR_L1 > 0)
                % Group-Huber fidelity (ring removal)
                residualSub = zeros(Detectors, numProjSub, SlicesZ,'single'); % residual for a chosen subset
                for kkk = 1:numProjSub
                    indC = CurrSubIndeces(kkk);
                    residualSub(:,kkk,:) =  squeeze(weights(:,indC,:)).*(squeeze(sino_updt_Sub(:,kkk,:)) - (squeeze(sino(:,indC,:)) - alpha_ring.*r_x));
                    sino_updt_FULL(:,indC,:) = squeeze(sino_updt_Sub(:,kkk,:)); % filling the full sinogram
                end
                
            elseif (students_data > 0)
                % student t data fidelity
                
                % artifacts removal with Students t penalty
                residualSub = squeeze(weights(:,CurrSubIndeces,:)).*(sino_updt_Sub - squeeze(sino(:,CurrSubIndeces,:)));
                
                for kkk = 1:SlicesZ
                    res_vec = reshape(residualSub(:,:,kkk), Detectors*numProjSub, 1); % 1D vectorized sinogram
                    %s = 100;
                    %gr = (2)*res_vec./(s*2 + conj(res_vec).*res_vec);
                    [ff, gr] = studentst(res_vec, 1);
                    residualSub(:,:,kkk) = reshape(gr, Detectors, numProjSub);
                end
                objective(i) = ff; % for the objective function output
            else
                % PWLS model
                residualSub = squeeze(weights(:,CurrSubIndeces,:)).*(sino_updt_Sub - squeeze(sino(:,CurrSubIndeces,:)));
                objective(i) = 0.5*norm(residualSub(:)); % for the objective function output
            end
            
            % perform backprojection of a subset
            if (strcmp(proj_geom.type,'parallel') || strcmp(proj_geom.type,'fanflat') || strcmp(proj_geom.type,'fanflat_vec'))
                % if geometry is 2D use slice-by-slice projection-backprojection routine
                x_temp = zeros(size(X),'single');
                for kkk = 1:SlicesZ
                    [x_temp(:,:,kkk)] = astra_create_backprojection_cuda(squeeze(residualSub(:,:,kkk))', proj_geomSUB, vol_geom);
                end
            else
                [id, x_temp] = astra_create_backprojection3d_cuda(residualSub, proj_geomSUB, vol_geom);
                astra_mex_data3d('delete', id);
            end
            
            X = X_t - L_const_inv.*x_temp;
            
            %--------------Regularisation part (CCPi-RGLTK)---------------%
            if (lambdaROF_TV > 0)
                % ROF-TV regularisation is enabled
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            X(:,:,kkk) = ROF_TV(single(X(:,:,kkk)), lambdaROF_TV*L_const_inv/subsets, round(IterationsRegul/subsets), Regul_time_step, tol);
                        else
                            X(:,:,kkk) = ROF_TV_GPU(single(X(:,:,kkk)), lambdaROF_TV*L_const_inv/subsets, round(IterationsRegul/subsets), Regul_time_step, tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = ROF_TV(X, lambdaROF_TV*L_const_inv/subsets, round(IterationsRegul/subsets), Regul_time_step, tol);
                    else
                        % GPU
                        X = ROF_TV_GPU(X, lambdaROF_TV*L_const_inv/subsets, round(IterationsRegul/subsets), Regul_time_step, tol);
                    end
                end
                f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaROF_TV*L_const_inv/subsets, 2)); % get TV energy value
                objective(i) = (objective(i) + f_valTV);
            end
            if (lambdaFGP_TV > 0)
                % FGP-TV regularisation is enabled
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            % CPU
                            X(:,:,kkk) = FGP_TV(X(:,:,kkk), lambdaFGP_TV*L_const_inv/subsets, round(IterationsRegul/subsets), tol);
                        else
                            % GPU
                            X(:,:,kkk) = FGP_TV_GPU(X(:,:,kkk), lambdaFGP_TV*L_const_inv/subsets, round(IterationsRegul/subsets), tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = FGP_TV(X, lambdaFGP_TV*L_const_inv/subsets, round(IterationsRegul/subsets), tol);
                    else
                        % GPU
                        X = FGP_TV_GPU(X, lambdaFGP_TV*L_const_inv/subsets, round(IterationsRegul/subsets), tol);
                    end
                end
                f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaFGP_TV*L_const_inv/subsets, 2)); % get TV energy value
                objective(i) = (objective(i) + f_valTV);
            end
            if (lambdaSB_TV > 0)
                % Split Bregman regularisation is enabled
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            % CPU
                            X(:,:,kkk) = SB_TV(X(:,:,kkk), lambdaSB_TV*L_const_inv/subsets, IterationsRegul, tol);
                        else
                            % GPU
                            X(:,:,kkk) = SB_TV_GPU(X(:,:,kkk), lambdaSB_TV*L_const_inv/subsets, IterationsRegul, tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = SB_TV(X, lambdaSB_TV*L_const_inv/subsets, round(IterationsRegul), tol);
                    else
                        % GPU
                        X = SB_TV_GPU(X, lambdaSB_TV*L_const_inv/subsets, round(IterationsRegul), tol);
                    end
                end
                f_valTV = 0.5*(TV_energy(single(X),single(X),lambdaSB_TV*L_const_inv/subsets, 2)); % get TV energy value
                objective(i) = (objective(i) + f_valTV);
            end
            if (lambdaDiffusion > 0)
                % Nonlinear diffusion regularisation is enabled
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            % CPU
                            X(:,:,kkk) = NonlDiff(X(:,:,kkk), lambdaDiffusion*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, FuncDiff_Type, tol);
                        else
                            % GPU
                            X(:,:,kkk) = NonlDiff_GPU(X(:,:,kkk), lambdaDiffusion*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, FuncDiff_Type, tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = NonlDiff(X, lambdaDiffusion*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, FuncDiff_Type, tol);
                    else
                        % GPU
                        X = NonlDiff(X, lambdaDiffusion*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, FuncDiff_Type, tol);
                    end
                end
                objective(i) = objective(i);
            end
            if (lambdaDiffusion4th > 0)
                % Anisotropic diffusion of 4th order regularisation is enabled
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            % CPU
                            X(:,:,kkk) = Diffusion_4thO(X(:,:,kkk), lambdaDiffusion4th*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, tol);
                        else
                            % GPU
                            X(:,:,kkk) = Diffusion_4thO_GPU(X(:,:,kkk), lambdaDiffusion4th*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = Diffusion_4thO(X, lambdaDiffusion4th*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, tol);
                    else
                        % GPU
                        X = Diffusion_4thO_GPU(X, lambdaDiffusion4th*L_const_inv/subsets, sigmaEdge, round(IterationsRegul/subsets), Regul_time_step, tol);
                    end
                end
                objective(i) = objective(i);
            end
            if (lambdaTGV > 0)
                % TGV
                if ((strcmp('2D', Dimension) == 1))
                    % 2D regularisation
                    for kkk = 1:SlicesZ
                        if (device == 0)
                            % CPU
                            X(:,:,kkk) = TGV(X(:,:,kkk), lambdaTGV*L_const_inv/subsets, alpha1, alpha0, round(IterationsRegul/subsets), 12.0, tol);
                        else
                            % GPU
                            X(:,:,kkk) = TGV_GPU(X(:,:,kkk), lambdaTGV*L_const_inv/subsets, alpha1, alpha0, round(IterationsRegul/subsets), 12.0, tol);
                        end
                    end
                else
                    % 3D regularisation
                    if (device == 0)
                        % CPU
                        X = TGV(X, lambdaTGV*L_const_inv/subsets, alpha1, alpha0, round(IterationsRegul/subsets), 12.0, tol);
                    else
                        % GPU
                        X = TGV_GPU(X, lambdaTGV*L_const_inv/subsets, alpha1, alpha0, round(IterationsRegul/subsets), 12.0, tol);
                    end
                end
            end
            
            
            t = (1 + sqrt(1 + 4*t^2))/2; % updating t
            X_t = X + ((t_old-1)/t).*(X - X_old); % updating X
            counterInd = counterInd + numProjSub;
        end
        
        if (i == 1)
            r_old = r;
        end
        
        % working with a 'ring vector'
        if (lambdaR_L1 > 0)
            r =  max(abs(r)-lambdaR_L1, 0).*sign(r); % soft-thresholding operator for ring vector
            r_x = r + ((t_old-1)/t).*(r - r_old); % updating r
        end
        
        if (show == 1)
            figure(10); imshow(X(:,:,slice), [0 maxvalplot]);
            if (lambdaR_L1 > 0)
                figure(11); plot(r); title('Rings offset vector')
            end
            pause(0.01);
        end
        
        if (strcmp(phantomExact, 'none' ) == 0)
            Resid_error(i) = RMSE(X(ROI), phantomExact(ROI));
            fprintf('%s %i %s %s %.4f  %s %s %f \n', 'Iteration Number:', i, '|', 'Error RMSE:', Resid_error(i), '|', 'Objective:', objective(i));
        else
            fprintf('%s %i  %s %s %f \n', 'Iteration Number:', i, '|', 'Objective:', objective(i));
        end
    end
end

output.Resid_error = Resid_error;
output.objective = objective;
output.L_const = L_const;

end
