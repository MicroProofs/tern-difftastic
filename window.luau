--!strict
-- `dft --tab` writes a request file (<tmp>/dft-view/<pane>-<socket hash>.dftview) and runs
-- `tern open --tab` on it; this route turns that open into the viewer block.

tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
	if string.match(req.path, "%.dftview$") then
		return { block = "dft-viewer.diff", args = { req.path } }
	end
	return nil
end)
