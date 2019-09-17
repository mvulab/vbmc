function [optimState,t_active,t_func] = ...
    activesample_vbmc(optimState,Ns,funwrapper,vp,vp_old,gp,options)
%ACTIVESAMPLE_VBMC Actively sample points iteratively based on acquisition function.

NSsearch = options.NSsearch;    % Number of points for acquisition fcn
t_func = 0;

timer_active = tic;

if isempty(gp)
    
    % No GP yet, just use provided points or sample from plausible box
    [optimState,t_func] = ...
        initdesign_vbmc(optimState,Ns,funwrapper,t_func,options);
    
else                    % Active uncertainty sampling
    
    SearchAcqFcn = options.SearchAcqFcn;
        
    for is = 1:Ns

        % Re-evaluate variance of the log joint
        [~,~,varF] = gplogjoint(vp,gp,0,0,0,1);
        optimState.varlogjoint_samples = varF;
        
        optimState.acqrand = rand();    % Seed for random acquisition fcn
        
        % Create search set from cache and randomly generated
        [Xsearch,idx_cache] = getSearchPoints(NSsearch,optimState,vp,options);
        Xsearch = real2int_vbmc(Xsearch,vp.trinfo,optimState.integervars);
        
        % Evaluate acquisition function
        acq_fast = SearchAcqFcn{1}(Xsearch,vp,gp,optimState,0);

        if options.SearchCacheFrac > 0
            [~,ord] = sort(acq_fast,'ascend');
            optimState.SearchCache = Xsearch(ord,:);
            idx = ord(1);
        else
            [~,idx] = min(acq_fast);
        end
        % idx/numel(acq_fast)
        Xacq = Xsearch(idx,:);
        idx_cache_acq = idx_cache(idx);
        
        % Remove selected points from search set
        Xsearch(idx,:) = []; idx_cache(idx) = [];
        % [size(Xacq,1),size(Xacq2,1)]
        
        % Additional search with CMA-ES
        if options.SearchCMAES
            if options.SearchCMAESVPInit
                [~,Sigma] = vbmc_moments(vp,0);       
            else
                X_hpd = gethpd_vbmc(optimState,options);
                Sigma = cov(X_hpd,1);
            end
            insigma = sqrt(diag(Sigma));
            fval_old = SearchAcqFcn{1}(Xacq(1,:),vp,gp,optimState,0);
            cmaes_opts = options.CMAESopts;
            cmaes_opts.TolFun = max(1e-12,abs(fval_old*1e-3));
            x0 = real2int_vbmc(Xacq(1,:),vp.trinfo,optimState.integervars)';
            [xsearch_cmaes,fval_cmaes] = cmaes_modded(func2str(SearchAcqFcn{1}),x0,insigma,cmaes_opts,vp,gp,optimState,1);
            if fval_cmaes < fval_old            
                Xacq(1,:) = real2int_vbmc(xsearch_cmaes',vp.trinfo,optimState.integervars);
                idx_cache_acq(1) = 0;
                % idx_cache = [idx_cache(:); 0];
                % Double check if the cache indexing is correct
            end
        end
        
        if options.UncertaintyHandling && options.RepeatedObservations
            % Re-evaluate acquisition function on training set
            X_train = get_traindata(optimState,options);
            
            % Disable variance-based regularization first
            oldflag = optimState.VarianceRegularizedAcqFcn;
            optimState.VarianceRegularizedAcqFcn = false;
            acq_train = SearchAcqFcn{1}(X_train,vp,gp,optimState,0);
            optimState.VarianceRegularizedAcqFcn = oldflag;
            
            [acq_train,idx_train] = min(acq_train);            
            acq_now = SearchAcqFcn{1}(Xacq(1,:),vp,gp,optimState,0);
            
            % [acq_train,acq_now]
            
            if acq_train < options.RepeatedAcqDiscount*acq_now
                Xacq(1,:) = X_train(idx_train,:);                
            end            
        end
        
        y_orig = [NaN; optimState.Cache.y_orig(:)]; % First position is NaN (not from cache)
        yacq = y_orig(idx_cache_acq+1);
        idx_nn = ~isnan(yacq);
        if any(idx_nn)
            yacq(idx_nn) = yacq(idx_nn) + warpvars_vbmc(Xacq(idx_nn,:),'logp',optimState.trinfo);
        end
        
        xnew = Xacq(1,:);
        idxnew = 1;
        
        % See if chosen point comes from starting cache
        idx = idx_cache_acq(idxnew);
        if idx > 0; y_orig = optimState.Cache.y_orig(idx); else; y_orig = NaN; end
        timer_func = tic;
        if isnan(y_orig)    % Function value is not available, evaluate
            try
                [ynew,optimState,idx_new] = funlogger_vbmc(funwrapper,xnew,optimState,'iter');
            catch func_error
                pause
            end
        else
            [ynew,optimState,idx_new] = funlogger_vbmc(funwrapper,xnew,optimState,'add',y_orig);
            % Remove point from starting cache
            optimState.Cache.X_orig(idx,:) = [];
            optimState.Cache.y_orig(idx) = [];
        end
        t_func = t_func + toc(timer_func);
            
        % ynew = outputwarp(ynew,optimState,options);
        if isfield(optimState,'S')
            s2new = optimState.S(idx_new)^2;
        else
            s2new = [];
        end
        
        % Perform simple rank-1 update if no noise and first sample
        update1 = (isempty(s2new) || optimState.nevals(idx_new) == 1) && ~options.NoiseShaping;
        if update1
            gp = gplite_post(gp,xnew,ynew,[],[],[],s2new,1);
        else
            [X_train,y_train,s2_train] = get_traindata(optimState,options);
            gp.X = X_train;
            gp.y = y_train;
            gp.s2 = s2_train;
            gp = gplite_post(gp);            
        end
    end
    
end

t_active = toc(timer_active) - t_func;
    
end

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
function [Xsearch,idx_cache] = getSearchPoints(NSsearch,optimState,vp,options)
%GETSEARCHPOINTS Get search points from starting cache or randomly generated.

% Take some points from starting cache, if not empty
x0 = optimState.Cache.X_orig;

if ~isempty(x0)
    cacheFrac = options.CacheFrac;  % Fraction of points from cache (if nonempty)
    Ncache = ceil(NSsearch*cacheFrac);            
    idx_cache = randperm(size(x0,1),min(Ncache,size(x0,1)));
    Xsearch = warpvars_vbmc(x0(idx_cache,:),'d',optimState.trinfo);        
else
    Xsearch = []; idx_cache = [];
end

% Randomly sample remaining points        
if size(Xsearch,1) < NSsearch
    Nrnd = NSsearch-size(Xsearch,1);
    
    Xrnd = [];
    Nsearchcache = round(options.SearchCacheFrac*Nrnd);
    if Nsearchcache > 0 % Take points from search cache
        Xrnd = [Xrnd; optimState.SearchCache(1:min(end,Nsearchcache),:)];
    end
    Nheavy = round(options.HeavyTailSearchFrac*Nrnd);
    if Nheavy > 0
        Xrnd = [Xrnd; vbmc_rnd(vp,Nheavy,0,1,3)];
    end
    Nmvn = round(options.MVNSearchFrac*Nrnd);
    if Nmvn > 0
        [mubar,Sigmabar] = vbmc_moments(vp,0);
        Xrnd = [Xrnd; mvnrnd(mubar,Sigmabar,Nmvn)];
    end
    Nhpd = round(options.HPDSearchFrac*Nrnd);
    if Nhpd > 0
        hpd_min = options.HPDFrac/8;
        hpd_max = options.HPDFrac;        
        hpdfracs = sort([rand(1,4)*(hpd_max-hpd_min) + hpd_min,hpd_min,hpd_max]);
        Nhpd_vec = diff(round(linspace(0,Nhpd,numel(hpdfracs)+1)));
        X = optimState.X(optimState.X_flag,:);
        y = optimState.y(optimState.X_flag);
        D = size(X,2);
        for ii = 1:numel(hpdfracs)
            if Nhpd_vec(ii) == 0; continue; end            
            [X_hpd,y_hpd] = gethpd_vbmc(optimState,struct('HPDFrac',hpdfracs(ii)));
            if isempty(X_hpd)
                [~,idxmax] = max(y);
                mubar = X(idxmax,:);
                Sigmabar = cov(X);
            else
                mubar = mean(X_hpd,1);
                Sigmabar = cov(X_hpd,1);
            end
            if isscalar(Sigmabar); Sigmabar = Sigmabar*ones(D,D); end
            %[~,idxmax] = max(y);
            %x0 = optimState.X(idxmax,:);
            %[Sigmabar,mubar] = covcma(X,y,x0,[],hpdfracs(ii));
            Xrnd = [Xrnd; mvnrnd(mubar,Sigmabar,Nhpd_vec(ii))];
        end
    end
    Nvp = max(0,Nrnd-Nsearchcache-Nheavy-Nmvn-Nhpd);
    if Nvp > 0
        Xrnd = [Xrnd; vbmc_rnd(vp,Nvp,0,1)];
    end
    
    Xsearch = [Xsearch; Xrnd];
    idx_cache = [idx_cache(:); zeros(Nrnd,1)];
end

end
