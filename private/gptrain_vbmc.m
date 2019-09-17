function [gp,hypstruct,Ns_gp] = gptrain_vbmc(hypstruct,optimState,stats,options)
%GPTRAIN_VBMC Train Gaussian process model.

% Initialize HYPSTRUCT if empty
hypfields = {'hyp','warp','logp','full','runcov'};
for f = hypfields
    if ~isfield(hypstruct,f{:}); hypstruct.(f{:}) = []; end
end

% Get priors, starting hyperparameters, and number of samples
if optimState.Warmup && options.BOWarmup
%        [hypprior,X_hpd,y_hpd,~,hyp0,optimState.gpMeanfun,Ns_gp] = ...
%            vbmc_gphyp(optimState,'const',0,options);
    [hypprior,~,~,~,hyp0,Ns_gp] = ...
        vbmc_gphyp(optimState,optimState.gpMeanfun,0,options);
else
    [hypprior,~,~,~,hyp0,Ns_gp] = ...
        vbmc_gphyp(optimState,optimState.gpMeanfun,0,options);
end

% Initial GP hyperparameters
if isempty(hypstruct.hyp); hypstruct.hyp = hyp0; end

% Get GP training options
gptrain_options = get_GPTrainOptions(Ns_gp,hypstruct,optimState,stats,options);    
gptrain_options.LogP = hypstruct.logp;
if numel(gptrain_options.Widths) ~= numel(hyp0); gptrain_options.Widths = []; end    

% Get training dataset
[X_train,y_train,s2_train] = get_traindata(optimState,options);
% optimState.warp_thresh = []; % max(y_train) - 10*D;    
% y_train = outputwarp(y_train,optimState,options);   % Fitness shaping

% Fit GP to training set
[gp,hypstruct.hyp,gpoutput] = gplite_train(hypstruct.hyp,Ns_gp,...
    X_train,y_train, ...
    optimState.gpCovfun,optimState.gpMeanfun,optimState.gpNoisefun,...
    s2_train,hypprior,gptrain_options);
hypstruct.full = gpoutput.hyp_prethin; % Pre-thinning GP hyperparameters
hypstruct.logp = gpoutput.logp;

%      if iter > 10
%          pause
%      end

% Update running average of GP hyperparameter covariance (coarse)
if size(hypstruct.full,2) > 1
    hypcov = cov(hypstruct.full');
    if isempty(hypstruct.runcov) || options.HypRunWeight == 0
        hypstruct.runcov = hypcov;
    else
        weight = options.HypRunWeight^options.FunEvalsPerIter;
        hypstruct.runcov = (1-weight)*hypcov + ...
            weight*hypstruct.runcov;
    end
else
    hypstruct.runcov = [];
end

% Sample from GP (for debug)
if ~isempty(gp) && 0
    Xgp = vbmc_gpsample(gp,1e3,optimState,1);
    cornerplot(Xgp);
end
