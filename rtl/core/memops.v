////////////////////////////////////////////////////////////////////////////////
//
// Filename:	memops.v
//
// Project:	Zip CPU -- a small, lightweight, RISC CPU soft core
//
// Purpose:	A memory unit to support a CPU.
//
//	In the interests of code simplicity, this memory operator is 
//	susceptible to unknown results should a new command be sent to it
//	before it completes the last one.  Unpredictable results might then
//	occurr.
//
//	20150919 -- Added support for handling BUS ERR's (i.e., the WB
//		error signal).
//
// Creator:	Dan Gisselquist, Ph.D.
//		Gisselquist Technology, LLC
//
////////////////////////////////////////////////////////////////////////////////
//
// Copyright (C) 2015,2017-2018, Gisselquist Technology, LLC
//
// This program is free software (firmware): you can redistribute it and/or
// modify it under the terms of  the GNU General Public License as published
// by the Free Software Foundation, either version 3 of the License, or (at
// your option) any later version.
//
// This program is distributed in the hope that it will be useful, but WITHOUT
// ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY or
// FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License
// for more details.
//
// You should have received a copy of the GNU General Public License along
// with this program.  (It's in the $(ROOT)/doc directory.  Run make with no
// target there if the PDF file isn't present.)  If not, see
// <http://www.gnu.org/licenses/> for a copy.
//
// License:	GPL, v3, as defined and found on www.gnu.org,
//		http://www.gnu.org/licenses/gpl.html
//
//
////////////////////////////////////////////////////////////////////////////////
//
//
`default_nettype	none
//
module	memops(i_clk, i_reset, i_stb, i_lock,
		i_op, i_addr, i_data, i_oreg,
			o_busy, o_valid, o_err, o_wreg, o_result,
		o_wb_cyc_gbl, o_wb_cyc_lcl,
			o_wb_stb_gbl, o_wb_stb_lcl,
			o_wb_we, o_wb_addr, o_wb_data, o_wb_sel,
		i_wb_ack, i_wb_stall, i_wb_err, i_wb_data
`ifdef	FORMAL
		, f_nreqs, f_nacks, f_outstanding
`endif
		);
	parameter	ADDRESS_WIDTH=30;
	parameter [0:0]	IMPLEMENT_LOCK=1'b1,
			WITH_LOCAL_BUS=1'b1,
			OPT_ALIGNMENT_ERR=1'b1,
			OPT_ZERO_ON_IDLE=1'b0;
	parameter [0:0]	F_OPT_CLK2FFLOGIC = 1'b0;
	localparam	AW=ADDRESS_WIDTH;
	input	wire		i_clk, i_reset;
	input	wire		i_stb, i_lock;
	// CPU interface
	input	wire	[2:0]	i_op;
	input	wire	[31:0]	i_addr;
	input	wire	[31:0]	i_data;
	input	wire	[4:0]	i_oreg;
	// CPU outputs
	output	wire		o_busy;
	output	reg		o_valid;
	output	reg		o_err;
	output	reg	[4:0]	o_wreg;
	output	reg	[31:0]	o_result;
	// Wishbone outputs
	output	wire		o_wb_cyc_gbl;
	output	reg		o_wb_stb_gbl;
	output	wire		o_wb_cyc_lcl;
	output	reg		o_wb_stb_lcl;
	output	reg		o_wb_we;
	output	reg	[(AW-1):0]	o_wb_addr;
	output	reg	[31:0]	o_wb_data;
	output	reg	[3:0]	o_wb_sel;
	// Wishbone inputs
	input	wire		i_wb_ack, i_wb_stall, i_wb_err;
	input	wire	[31:0]	i_wb_data;
// Formal
	parameter	F_LGDEPTH = 2;
`ifdef	FORMAL
	output	wire	[(F_LGDEPTH-1):0]	f_nreqs, f_nacks, f_outstanding;
`endif

	reg	misaligned;

	generate if (OPT_ALIGNMENT_ERR)
	begin : GENERATE_ALIGNMENT_ERR
		always @(*)
		casez({ i_op[2:1], i_addr[1:0] })
		4'b01?1: misaligned = i_stb; // Words must be halfword aligned
		4'b0110: misaligned = i_stb; // Words must be word aligned
		4'b10?1: misaligned = i_stb; // Halfwords must be aligned
		// 4'b11??: misaligned <= 1'b0; Byte access are never misaligned
		default: misaligned = 1'b0;
		endcase
	end else
		always @(*)	misaligned = 1'b0;
	endgenerate

	reg	r_wb_cyc_gbl, r_wb_cyc_lcl;
	wire	gbl_stb, lcl_stb;
	assign	lcl_stb = (i_stb)&&(WITH_LOCAL_BUS!=0)&&(i_addr[31:24]==8'hff)
				&&(!misaligned);
	assign	gbl_stb = (i_stb)&&((WITH_LOCAL_BUS==0)||(i_addr[31:24]!=8'hff))
				&&(!misaligned);

	initial	r_wb_cyc_gbl = 1'b0;
	initial	r_wb_cyc_lcl = 1'b0;
	always @(posedge i_clk)
		if (i_reset)
		begin
			r_wb_cyc_gbl <= 1'b0;
			r_wb_cyc_lcl <= 1'b0;
		end else if ((r_wb_cyc_gbl)||(r_wb_cyc_lcl))
		begin
			if ((i_wb_ack)||(i_wb_err))
			begin
				r_wb_cyc_gbl <= 1'b0;
				r_wb_cyc_lcl <= 1'b0;
			end
		end else begin // New memory operation
			// Grab the wishbone
			r_wb_cyc_lcl <= (lcl_stb);
			r_wb_cyc_gbl <= (gbl_stb);
		end
	initial	o_wb_stb_gbl = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_wb_stb_gbl <= 1'b0;
	else if ((i_wb_err)&&(r_wb_cyc_gbl))
		o_wb_stb_gbl <= 1'b0;
	else if (o_wb_cyc_gbl)
		o_wb_stb_gbl <= (o_wb_stb_gbl)&&(i_wb_stall);
	else
		// Grab wishbone on any new transaction to the gbl bus
		o_wb_stb_gbl <= (gbl_stb);

	initial	o_wb_stb_lcl = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_wb_stb_lcl <= 1'b0;
	else if ((i_wb_err)&&(r_wb_cyc_lcl))
		o_wb_stb_lcl <= 1'b0;
	else if (o_wb_cyc_lcl)
		o_wb_stb_lcl <= (o_wb_stb_lcl)&&(i_wb_stall);
	else
		// Grab wishbone on any new transaction to the lcl bus
		o_wb_stb_lcl  <= (lcl_stb);

	reg	[3:0]	r_op;
	initial	o_wb_we   = 1'b0;
	initial	o_wb_data = 0;
	initial	o_wb_sel  = 0;
	always @(posedge i_clk)
	if (i_stb)
	begin
		o_wb_we   <= i_op[0];
		if (OPT_ZERO_ON_IDLE)
		begin
			casez({ i_op[2:1], i_addr[1:0] })
			4'b100?: o_wb_data <= { i_data[15:0], 16'h00 };
			4'b101?: o_wb_data <= { 16'h00, i_data[15:0] };
			4'b1100: o_wb_data <= {         i_data[7:0], 24'h00 };
			4'b1101: o_wb_data <= {  8'h00, i_data[7:0], 16'h00 };
			4'b1110: o_wb_data <= { 16'h00, i_data[7:0],  8'h00 };
			4'b1111: o_wb_data <= { 24'h00, i_data[7:0] };
			default: o_wb_data <= i_data;
			endcase
		end else
			casez({ i_op[2:1], i_addr[1:0] })
			4'b10??: o_wb_data <= { (2){ i_data[15:0] } };
			4'b11??: o_wb_data <= { (4){ i_data[7:0] } };
			default: o_wb_data <= i_data;
			endcase

		o_wb_addr <= i_addr[(AW+1):2];
		casez({ i_op[2:1], i_addr[1:0] })
		4'b01??: o_wb_sel <= 4'b1111;
		4'b100?: o_wb_sel <= 4'b1100;
		4'b101?: o_wb_sel <= 4'b0011;
		4'b1100: o_wb_sel <= 4'b1000;
		4'b1101: o_wb_sel <= 4'b0100;
		4'b1110: o_wb_sel <= 4'b0010;
		4'b1111: o_wb_sel <= 4'b0001;
		default: o_wb_sel <= 4'b1111;
		endcase
		r_op <= { i_op[2:1] , i_addr[1:0] };
	end else if ((OPT_ZERO_ON_IDLE)&&(!o_wb_cyc_gbl)&&(!o_wb_cyc_lcl))
	begin
		o_wb_we   <= 1'b0;
		o_wb_addr <= 0;
		o_wb_data <= 32'h0;
		o_wb_sel  <= 4'h0;
	end

	initial	o_valid = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_valid <= 1'b0;
	else
		o_valid <= (((o_wb_cyc_gbl)||(o_wb_cyc_lcl))
				&&(i_wb_ack)&&(!o_wb_we));
	initial	o_err = 1'b0;
	always @(posedge i_clk)
	if (i_reset)
		o_err <= 1'b0;
	else if ((r_wb_cyc_gbl)||(r_wb_cyc_lcl))
		o_err <= i_wb_err;
	else if ((i_stb)&&(!o_busy))
		o_err <= misaligned;
	else
		o_err <= 1'b0;

	assign	o_busy = (r_wb_cyc_gbl)||(r_wb_cyc_lcl);

	always @(posedge i_clk)
	if (i_stb)
		o_wreg    <= i_oreg;
	always @(posedge i_clk)
	if ((OPT_ZERO_ON_IDLE)&&(!i_wb_ack))
		o_result <= 32'h0;
	else begin
		casez(r_op)
		4'b01??: o_result <= i_wb_data;
		4'b100?: o_result <= { 16'h00, i_wb_data[31:16] };
		4'b101?: o_result <= { 16'h00, i_wb_data[15: 0] };
		4'b1100: o_result <= { 24'h00, i_wb_data[31:24] };
		4'b1101: o_result <= { 24'h00, i_wb_data[23:16] };
		4'b1110: o_result <= { 24'h00, i_wb_data[15: 8] };
		4'b1111: o_result <= { 24'h00, i_wb_data[ 7: 0] };
		default: o_result <= i_wb_data;
		endcase
	end

	reg	lock_gbl, lock_lcl;

	generate
	if (IMPLEMENT_LOCK != 0)
	begin

		initial	lock_gbl = 1'b0;
		initial	lock_lcl = 1'b0;

		always @(posedge i_clk)
		if (i_reset)
		begin
			lock_gbl <= 1'b0;
			lock_lcl <= 1'b0;
		end else if (((i_wb_err)&&((r_wb_cyc_gbl)||(r_wb_cyc_lcl)))
				||(misaligned))
		begin
			// Kill the lock if
			//	there's a bus error, or
			//	User requests a misaligned memory op
			lock_gbl <= 1'b0;
			lock_lcl <= 1'b0;
		end else begin
			// Kill the lock if
			//	i_lock goes down
			//	User starts on the global bus, then switches
			//	  to local or vice versa
			lock_gbl <= (i_lock)&&((r_wb_cyc_gbl)||(lock_gbl))
					&&(!lcl_stb);
			lock_lcl <= (i_lock)&&((r_wb_cyc_lcl)||(lock_lcl))
					&&(!gbl_stb);
		end

		assign	o_wb_cyc_gbl = (r_wb_cyc_gbl)||(lock_gbl);
		assign	o_wb_cyc_lcl = (r_wb_cyc_lcl)||(lock_lcl);
	end else begin

		assign	o_wb_cyc_gbl = (r_wb_cyc_gbl);
		assign	o_wb_cyc_lcl = (r_wb_cyc_lcl);

		always @(*)
			{ lock_gbl, lock_lcl } = 2'b00;

		// Make verilator happy
		// verilator lint_off UNUSED
		wire	[2:0]	lock_unused;
		assign	lock_unused = { i_lock, lock_gbl, lock_lcl };
		// verilator lint_on  UNUSED

	end endgenerate

`ifdef	VERILATOR
	always @(posedge i_clk)
	if ((r_wb_cyc_gbl)||(r_wb_cyc_lcl))
		assert(!i_stb);
`endif


	// Make verilator happy
	// verilator lint_off UNUSED
	generate if (AW < 22)
	begin : TOO_MANY_ADDRESS_BITS

		wire	[(21-AW):0] unused_addr;
		assign	unused_addr = i_addr[23:(AW+2)];

	end endgenerate
	// verilator lint_on  UNUSED

`ifdef	FORMAL
`ifdef	MEMOPS
`define	ASSUME	assume
`define	ASSERT	assert
	generate if (F_OPT_CLK2FFLOGIC)
	begin
		reg	f_last_clk;
		initial	f_last_clk = 0;
		always @($global_clock)
		begin
			assume(i_clk != f_last_clk);
			f_last_clk <= i_clk;
		end
	end endgenerate
`else
`define	ASSUME	assert
`define	ASSERT	assume
`endif

	reg	f_past_valid;
	initial	f_past_valid = 0;
	always @(posedge i_clk)
		f_past_valid = 1'b1;
	always @(*)
		if (!f_past_valid)
			`ASSUME(i_reset);
	initial	`ASSUME(!i_stb);

	generate if (F_OPT_CLK2FFLOGIC)
	begin
		always @($global_clock)
		if (!$rose(i_clk))
		begin
			assume($stable(i_reset));
			assume($stable(i_stb));
			assume($stable(i_addr));
			assume($stable(i_op));
			assume($stable(i_lock));
		end
	end endgenerate

	wire	f_cyc, f_stb;
	assign	f_cyc = (o_wb_cyc_gbl)||(o_wb_cyc_lcl);
	assign	f_stb = (o_wb_stb_gbl)||(o_wb_stb_lcl);

`ifdef	MEMOPS
`define	MASTER	fwb_master
`else
`define	MASTER	fwb_counter
`endif

	fwb_master #(.AW(AW), .F_LGDEPTH(F_LGDEPTH),
			.F_OPT_CLK2FFLOGIC(F_OPT_CLK2FFLOGIC),
			.F_OPT_RMW_BUS_OPTION(IMPLEMENT_LOCK),
			.F_OPT_DISCONTINUOUS(IMPLEMENT_LOCK))
		f_wb(i_clk, i_reset,
			f_cyc, f_stb, o_wb_we, o_wb_addr, o_wb_data, o_wb_sel,
			i_wb_ack, i_wb_stall, i_wb_data, i_wb_err,
			f_nreqs, f_nacks, f_outstanding);


	// Rule: Only one of the two CYC's may be valid, never both
	always @(posedge i_clk)
		`ASSERT((!o_wb_cyc_gbl)||(!o_wb_cyc_lcl));

	// Rule: Only one of the two STB's may be valid, never both
	always @(posedge i_clk)
		`ASSERT((!o_wb_stb_gbl)||(!o_wb_stb_lcl));

	// Rule: if WITH_LOCAL_BUS is ever false, neither the local STB nor CYC
	// may be valid
	always @(*)
		if (!WITH_LOCAL_BUS)
		begin
			`ASSERT(!o_wb_cyc_lcl);
			`ASSERT(!o_wb_stb_lcl);
		end

	// Rule: If the global CYC is ever true, the LCL one cannot be true
	// on the next clock without an intervening idle of both
	always @(posedge i_clk)
		if ((f_past_valid)&&($past(r_wb_cyc_gbl)))
			`ASSERT(!r_wb_cyc_lcl);

	// Same for if the LCL CYC is true
	always @(posedge i_clk)
		if ((f_past_valid)&&($past(r_wb_cyc_lcl)))
			`ASSERT(!r_wb_cyc_gbl);

	// STB can never be true unless CYC is also true
	always @(posedge i_clk)
		if (o_wb_stb_gbl)
			`ASSERT(r_wb_cyc_gbl);
	always @(posedge i_clk)
		if (o_wb_stb_lcl)
			`ASSERT(r_wb_cyc_lcl);

	// This core only ever has zero or one outstanding transaction(s)
	always @(posedge i_clk)
		if ((o_wb_stb_gbl)||(o_wb_stb_lcl))
			`ASSERT(f_outstanding == 0);
		else
			`ASSERT((f_outstanding == 0)||(f_outstanding == 1));

	// The LOCK function only allows up to two transactions (at most)
	// before CYC must be dropped.
	always @(posedge i_clk)
		if ((o_wb_stb_gbl)||(o_wb_stb_lcl))
		begin
			if (IMPLEMENT_LOCK)
				`ASSERT((f_outstanding == 0)||(f_outstanding == 1));
			else
				`ASSERT(f_nreqs <= 1);
		end

	always @(posedge i_clk)
	if ((f_past_valid)&&(o_busy))
	begin

		// If i_stb doesn't change, then neither do any of the other
		// inputs
		if (($past(i_stb))&&(i_stb))
		begin
			`ASSUME($stable(i_op));
			`ASSUME($stable(i_addr));
			`ASSUME($stable(i_data));
			`ASSUME($stable(i_oreg));
			`ASSUME($stable(i_lock));
		end


		// No strobe's are allowed if a request is outstanding, either
		// having been accepted by the bus or waiting to be accepted
		// by the bus.
		if ((f_outstanding != 0)||(f_stb))
			`ASSUME(!i_stb);
		/*
		if (o_busy)
			assert( (!i_stb)
				||((!o_wb_stb_gbl)&&(!o_wb_stb_lcl)&&(i_lock)));

		if ((f_cyc)&&($past(f_cyc)))
			assert($stable(r_op));
		*/
	end

	always @(*)
		if (!IMPLEMENT_LOCK)
			`ASSUME(!i_lock);

	always @(posedge i_clk)
		if ((f_past_valid)&&($past(f_cyc))&&($past(!i_lock)))
			`ASSUME(!i_lock);

	// Following any i_stb request, assuming we are idle, immediately
	// begin a bus transaction
	always @(posedge i_clk)
	if ((f_past_valid)&&($past(i_stb))
		&&(!$past(f_cyc))&&(!$past(i_reset)))
	begin
		if ($past(misaligned))
		begin
			`ASSERT(!f_cyc);
			`ASSERT(!o_busy);
			`ASSERT(o_err);
			`ASSERT(!o_valid);
		end else begin
			`ASSERT(f_cyc);
			`ASSERT(o_busy);
		end
	end

	always @(posedge i_clk)
	if (o_busy)
		`ASSUME(!i_stb);

	always @(posedge i_clk)
	if (o_wb_cyc_gbl)
		`ASSERT((o_busy)||(lock_gbl));

	always @(posedge i_clk)
	if (o_wb_cyc_lcl)
		`ASSERT((o_busy)||(lock_lcl));

	always @(posedge i_clk)
		if (f_outstanding > 0)
			`ASSERT(o_busy);

	// If a transaction ends in an error, send o_err on the output port.
	always @(posedge i_clk)
		if (f_past_valid)
		begin
			if ($past(i_reset))
				`ASSERT(!o_err);
			else if (($past(f_cyc))&&($past(i_wb_err)))
				`ASSERT(o_err);
			else if ($past(misaligned))
				`ASSERT(o_err);
		end

	// Always following a successful ACK, return an O_VALID value.
	always @(posedge i_clk)
		if (f_past_valid)
		begin
			if ($past(i_reset))
				`ASSERT(!o_valid);
			else if(($past(f_cyc))&&($past(i_wb_ack))
					&&(!$past(o_wb_we)))
				`ASSERT(o_valid);
			else if ($past(misaligned))
				`ASSERT((!o_valid)&&(o_err));
			else
				`ASSERT(!o_valid);
		end

	//always @(posedge i_clk)
	//	if ((f_past_valid)&&($past(f_cyc))&&(!$past(o_wb_we))&&($past(i_wb_ack)))

	/*
	input	wire	[2:0]	i_op;
	input	wire	[31:0]	i_addr;
	input	wire	[31:0]	i_data;
	input	wire	[4:0]	i_oreg;
	// CPU outputs
	output	wire		o_busy;
	output	reg		o_valid;
	output	reg		o_err;
	output	reg	[4:0]	o_wreg;
	output	reg	[31:0]	o_result;
	*/

	reg	[3:0]	r_op;
	initial	o_wb_we = 1'b0;
	always @(posedge i_clk)
	if ((f_past_valid)&&(!$past(i_reset))&&($past(i_stb)))
	begin
		// On a write, assert o_wb_we should be true
		assert( $past(i_op[0]) == o_wb_we);

		// Word write
		if ($past(i_op[2:1]) == 2'b01)
		begin
			`ASSERT(o_wb_sel == 4'hf);
			`ASSERT(o_wb_data == $past(i_data));
		end

		// Halfword (short) write
		if ($past(i_op[2:1]) == 2'b10)
		begin
			if (!$past(i_addr[1]))
			begin
				`ASSERT(o_wb_sel == 4'hc);
				`ASSERT(o_wb_data[31:16] == $past(i_data[15:0]));
			end else begin
				`ASSERT(o_wb_sel == 4'h3);
				`ASSERT(o_wb_data[15:0] == $past(i_data[15:0]));
			end
		end

		if ($past(i_op[2:1]) == 2'b11)
		begin
			if ($past(i_addr[1:0])==2'b00)
			begin
				`ASSERT(o_wb_sel == 4'h8);
				`ASSERT(o_wb_data[31:24] == $past(i_data[7:0]));
			end

			if ($past(i_addr[1:0])==2'b01)
			begin
				`ASSERT(o_wb_sel == 4'h4);
				`ASSERT(o_wb_data[23:16] == $past(i_data[7:0]));
			end
			if ($past(i_addr[1:0])==2'b10)
			begin
				`ASSERT(o_wb_sel == 4'h2);
				`ASSERT(o_wb_data[15:8] == $past(i_data[7:0]));
			end
			if ($past(i_addr[1:0])==2'b11)
			begin
				`ASSERT(o_wb_sel == 4'h1);
				`ASSERT(o_wb_data[7:0] == $past(i_data[7:0]));
			end
		end

		`ASSUME($past(i_op[2:1] != 2'b00));
	end

	// This logic is fixed in the definitions of the lock(s) above
	// i.e., the user cna be stupid and this will still work
	/*
	always @(posedge i_clk)
		if ((i_lock)&&(i_stb)&&(WITH_LOCAL_BUS))
		begin
			restrict((lock_gbl)||(i_addr[31:24] ==8'hff));
			restrict((lock_lcl)||(i_addr[31:24]!==8'hff));
		end
	*/

	always @(posedge i_clk)
		if (o_wb_stb_lcl)
			`ASSERT(o_wb_addr[29:22] == 8'hff);

	always @(posedge i_clk)
		if ((f_past_valid)&&(!$past(i_reset))&&($past(misaligned)))
		begin
			`ASSERT(!o_wb_cyc_gbl);
			`ASSERT(!o_wb_cyc_lcl);
			`ASSERT(!o_wb_stb_gbl);
			`ASSERT(!o_wb_stb_lcl);
			`ASSERT(o_err);
			//OPT_ALIGNMENT_ERR=1'b0,
			//OPT_ZERO_ON_IDLE=1'b0;
		end

	always @(posedge i_clk)
	if ((!f_past_valid)||($past(i_reset)))
		`ASSUME(!i_stb);
	always @(*)
	if (o_busy)
		`ASSUME(!i_stb);

	always @(posedge i_clk)
	if ((f_past_valid)&&(IMPLEMENT_LOCK)
		&&(!$past(i_reset))&&(!$past(i_wb_err))
		&&(!$past(misaligned))
		&&(!$past(lcl_stb))
		&&($past(i_lock))&&($past(lock_gbl)))
		assert(lock_gbl);

	always @(posedge i_clk)
	if ((f_past_valid)&&(IMPLEMENT_LOCK)
			&&(!$past(i_reset))&&(!$past(i_wb_err))
			&&(!$past(misaligned))
			&&(!$past(lcl_stb))
			&&($past(o_wb_cyc_gbl))&&($past(i_lock))
			&&($past(lock_gbl)))
		assert(o_wb_cyc_gbl);

	always @(posedge i_clk)
	if ((f_past_valid)&&(IMPLEMENT_LOCK)
			&&(!$past(i_reset))&&(!$past(i_wb_err))
			&&(!$past(misaligned))
			&&(!$past(gbl_stb))
			&&($past(o_wb_cyc_lcl))&&($past(i_lock))
			&&($past(lock_lcl)))
		assert(o_wb_cyc_lcl);

	//
	// Cover properties
	//
	always @(posedge i_clk)
		cover(i_wb_ack);

	// Cover a response on the same clock it is made
	always @(posedge i_clk)
		cover((o_wb_stb_gbl)&&(i_wb_ack));

	// Cover a response a clock later
	always @(posedge i_clk)
		cover((o_wb_stb_gbl)&&(i_wb_ack));


	generate if (WITH_LOCAL_BUS)
	begin

		// Same things on the local bus
		always @(posedge i_clk)
			cover((o_wb_cyc_lcl)&&(!o_wb_stb_lcl)&&(i_wb_ack));
		always @(posedge i_clk)
			cover((o_wb_stb_lcl)&&(i_wb_ack));

	end endgenerate

`ifdef	VERIFIC
	assert property @(posedge i_cll)
		disable iff (i_reset)||((o_wb_cyc_gbl)&&(i_wb_err))
		(gbl_stb)&&(!o_busy)
		|=> (o_busy)&&(o_wb_cyc_gbl)&&($stable(o_wb_we)) throughout
			// Poss. stalled request
			((o_wb_cyc_stb)&&(i_wb_stall) [*0:$]
			// Request goes through
		##1 or (((o_wb_cyc_gbl)&&(o_wb_cyc_stb)&&(!i_wb_stall))
				// and is immediately acked
				&&(i_wb_ack))
		// or wait for the ack
		  (o_wb_cyc_gbl)&&(o_wb_cyc_stb)&&(!i_wb_stall)&&(!i_wb_ack)
		##1 (o_wb_cyc_gbl)&&(!o_wb_cyc_stb)&&(!i_wb_ack) [*0:$]
		##1 (o_wb_cyc_gbl)&&(!o_wb_cyc_stb)&&(i_wb_ack))
		// and return a value to the bus
		##1 (o_valid)&&(o_result == $past(i_wb_data));
`endif
`endif
endmodule
//
//
// Usage (from yosys):
//		(BFOR)	(!ZOI,ALIGN)	(ZOI,ALIGN)	(!ZOI,!ALIGN)
//	Cells	 230		226		281		225
//	  FDRE	 114		116		116		116
//	  LUT2	  17		 23		 76		 19
//	  LUT3	   9		 23		 17		 20
//	  LUT4	  15		  4		 11		 14
//	  LUT5	  18		 18		  7		 15
//	  LUT6	  33		 18		 54		 38
//	  MUX7	  16		 12		  		  2
//	  MUX8	   8		  1				  1
//
//
