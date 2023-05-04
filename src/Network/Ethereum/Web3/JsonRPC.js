"use strict";


exports._sendAsync = function (provider) {
    return function (request) {
        return function(onError, onSuccess) {
            // // require('utils').
            // console.log("_sendAsync request", request)
            provider.sendAsync(request, function(err, succ) {
                // console.log("_sendAsync err, succ", { request, err, succ })
                // console.log("\n")
                if (err) {
                    onError(err);
                } else {
                    onSuccess(succ);
                }
            });
            return function (cancelError, onCancelerError, onCancelerSuccess) {
                onCancelerSuccess();
            };
        };
    };
};
