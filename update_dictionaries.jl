# Copyright (C) 2023 Heptazhou <zhou@0h7z.com>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as
# published by the Free Software Foundation, either version 3 of the
# License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.

using Pkg: Pkg
cd(@__DIR__)
Pkg.activate(".")
Pkg.Types.EnvCache().manifest.julia_version ≢ VERSION ?
Pkg.update() : (Pkg.resolve(); Pkg.instantiate())

using Base.Threads: @spawn, @threads, nthreads
using DataFrames: DataFrame
using DataFramesMeta
using FITSIO: FITS, Tables.columnnames
using JSON: json
using OrderedCollections

const IntOrFlt = Union{Int32, Int64, Float32, Float64}
const IntOrStr = Union{Int32, Int64, String}
const s_info(xs...) = @static nthreads() > 1 ? @spawn(@info string(xs...)) : @info string(xs...)
const u_sort! = unique! ∘ sort!

Base.convert(::Type{AS}, v::Vector) where AS <: AbstractSet{T} where T = AS(T[v;])
Base.isless(::Any, ::Number) = Bool(0)
Base.isless(::Number, ::Any) = Bool(1)

@static if VERSION < v"1.7"
	macro something(xs...)
		:(something($(esc.(xs)...)))
	end
end

@info "Looking for spAll file (*.fits|*.fits.tmp|*.fits.gz|*.7z)"

# https://data.sdss.org/datamodel/files/BOSS_SPECTRO_REDUX/RUN2D/spAll.html
# https://github.com/sciserver/sqlloader/blob/master/schema/sql/SpectroTables.sql
# https://www.sdss.org/dr18/data_access/bitmasks/
const cols = [
	:CATALOGID    # Int64    # SDSS-V CatalogID
	:FIELD        # Int64    # Field number
	:FIELDQUALITY # String   # Quality of field ("good" | "bad")
	:MJD          # Int64    # Modified Julian date of observation
	:MJD_FINAL    # Float64  # Mean MJD of the Coadded Spectra
	:OBJTYPE      # String   # Why this object was targetted; see spZbest
	:PROGRAMNAME  # String   # Program name within a given survey
	:RCHI2        # Float32  # Reduced χ² for best fit
	:SURVEY       # String   # Survey that plate is part of
	:Z            # Float32  # Redshift; assume that this redshift is incorrect if the ZWARNING flag is nonzero
	:ZWARNING     # Int64    # A flag set for bad redshift fits in place of calling CLASS=UNKNOWN; see bitmasks
]
const fits = try
	(f = mapreduce(x -> filter!(endswith(x), readdir()), vcat, [r"\.fits(\.tmp)?", r"\.fits\.gz"]))
	(f = [f; filter!(endswith(".7z"), readdir() |> reverse!)][1]) # must be single file archive
	(endswith(f, r"7z|gz") && (run(`7z x $f`); f = readlines(`7z l -ba -slt $f`)[1][8:end]))
	(endswith(f, r"\.tmp") && ((t, f) = (f, replace(f, r"\.tmp$" => "")); mv(t, f)); f)
catch
	throw(SystemError("*.fits", 2)) # ENOENT 2 No such file or directory
end
# FITS(fits)[2]

const df = @time @sync let
	# cols = columnnames(FITS(fits)[2]) # uncomment to read all the columns
	s_info("Reading ", length(cols), " columns from `$fits` (t = $(nthreads()))")
	@threads for col ∈ cols
		@eval $col = read(FITS(fits)[2], $(String(col)))
		@eval $col isa Vector || ($col = collect(Vector{eltype($col)}, eachcol($col)))
	end
	@chain DataFrame(@eval (; $(cols...))) begin
		@rsubset! :FIELDQUALITY ≡ "good"
		@select! $(Not(:FIELDQUALITY))
	end
end
# LittleDict(map(eltype, eachcol(df)), propertynames(df))

@info "Setting up dictionary for fieldIDs with each RM_field"

const programs =
	OrderedDict{String, OrderedSet{IntOrStr}}(
		"SDSS-RM"   => [15171, 15172, 15173, 15290, 16169, 20867, 112359, "all"],
		"XMMLSS-RM" => [15000, 15002, 23175, 112361, "all"],
		"COSMOS-RM" => [15038, 15070, 15071, 15252, 15253, 16163, 16164, 16165, 20868, 23288, 112360, "all"],
	)

@info "Sorting out the fields (including the `all` option if instructed to do so)"

const programs_cats = @time @sync let
	f_programs_dict = OrderedDict{String, Expr}(
		"eFEDS1"       => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "eFEDS1"),
		"eFEDS2"       => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "eFEDS2"),
		"eFEDS3"       => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "eFEDS3"),
		"MWM3"         => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "MWM3"),
		"MWM4"         => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "MWM4"),
		"AQMES-Bonus"  => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "AQMES-Bonus"),
		"AQMES-Wide"   => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "AQMES-Wide"),
		"AQMES-Medium" => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ≡ "AQMES-Medium"),
		"RM-Plates"    => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "QSO" && :PROGRAMNAME ∈ ("RM", "RMv2", "RMv2-fewMWM")),
		"RM-Fibers"    => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "bhm_rm"),
		"bhm_aqmes"    => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "bhm_aqmes"),
		"bhm_csc"      => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "bhm_csc"),
		"bhm_filler"   => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "bhm_filler"),
		"bhm_spiders"  => :(:SURVEY ≡ "BHM" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "bhm_spiders"),
		"open_fiber"   => :(:SURVEY ≡ "open_fiber" && :OBJTYPE ≡ "science" && :PROGRAMNAME ≡ "open_fiber"),
	)
	foreach(sort!, programs.vals)
	all_program(df) = @eval @rsubset df any([$(f_programs_dict.vals...)])
	all_catalogs    = @spawn @chain all_program(df) @select!(:CATALOGID) _[!, 1] sort! OrderedSet
	for (k, v) ∈ f_programs_dict
		program(df) = @eval @rsubset df $v
		programs[k] = IntOrStr[@chain program(df) @select!(:FIELD) _[!, 1] u_sort!; "all"]
	end
	all_catalogs |> fetch
end

@info "Filling fieldIDs and catalogIDs with only science targets and completed epochs"

const fieldIDs = @time @sync let
	get_data_of(ids::OrderedSet{Integer}) = @chain df begin # :FIELD
		@select :CATALOGID :FIELD :SURVEY :OBJTYPE
		@rsubset! :FIELD ∈ ids && :SURVEY ≡ "BHM" && :OBJTYPE ∈ ("QSO", "science")
		@by :FIELD :CATALOGID = [:CATALOGID]
		eachrow
	end
	d = OrderedDict{String, Vector{Int64}}()
	s_info("Processing ", sum(length, programs.vals), " entries of ", length(programs), " programs")
	for (prog, opts) ∈ programs
		data = get_data_of(filter(≠("all"), opts) |> OrderedSet{Integer})
		for (k, v) ∈ data
			(k, v) = string(k), copy(v)
			(haskey(d, k) ? append!(d[k], v) : d[k] = v) |> u_sort!
		end
		d["$prog-all"] = mapreduce(p -> p[:CATALOGID], vcat, data, init = valtype(d)()) |> u_sort!
	end
	sort!(d, by = s -> @something tryparse(Int64, s) s)
end

@info "Building dictionary for catalogIDs"

const catalogIDs = @time @sync let
	get_data_of(ids::OrderedSet{Integer}) = @chain df begin # :CATALOGID
		@select :CATALOGID :FIELD :MJD :MJD_FINAL :RCHI2 :Z :ZWARNING
		@rsubset! :CATALOGID ∈ ids
		@orderby :CATALOGID 0 .< :ZWARNING :RCHI2
		@by :CATALOGID begin
			:META = [(collect ∘ eachrow)(IntOrFlt[:ZWARNING :Z :RCHI2])[1]]
			:DATA = [(collect ∘ eachrow)(IntOrFlt[:FIELD :MJD :MJD_FINAL])]
		end
		@rselect! :ks = string(:CATALOGID) :vs = [:META, sort!(:DATA)...]
		_[!, 1], _[!, 2]
	end
	s_info("Processing ", length(programs_cats), " entries")
	d = LittleDict(get_data_of(programs_cats |> OrderedSet{Integer})...)
end

@info "Dumping dictionaries to file"
write("dictionaries.txt", json([programs, fieldIDs, catalogIDs]), "\n")

