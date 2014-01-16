/***************************************************************
This code was generated by  Spiral 5.0 beta, www.spiral.net --
Copyright (c) 2005, Carnegie Mellon University
All rights reserved.
The code is distributed under a BSD style license
(see http://www.opensource.org/licenses/bsd-license.php)

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

* Redistributions of source code must retain the above copyright
  notice, reference to Spiral, this list of conditions and the
  following disclaimer.
  * Redistributions in binary form must reproduce the above
  copyright notice, this list of conditions and the following
  disclaimer in the documentation and/or other materials provided
  with the distribution.
  * Neither the name of Carnegie Mellon University nor the name of its
  contributors may be used to endorse or promote products derived from
  this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
*AS IS* AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
******************************************************************/

use fft, Time;

config const NUMRUNS = 1000;
config const MIN_SIZE = 1;
config const MAX_SIZE = 11;
config const EPS = 1.0E-5;

config param printTimings = true;

proc main() {
  var startTime:real, execTime:real;
  var numruns : int = NUMRUNS;

  writeln("Spiral 5.0 Chapel FFT example\n");

  for n in MIN_SIZE..MAX_SIZE {
    var N : int = 2**n;
    const Ndom: domain(1) = {0..N-1};
    type Ntype = [Ndom] complex;
    var X : Ntype, Y : Ntype;
    const ops = 5.0 * N * log2(N);
    
    //  initialization
    numruns = (numruns*0.7): int;
    X(0) = 1+1.0i;
    forall i in 1..N-1 {
      X(i) = 0;
    }
    init_fft(N);
    
    //  check computation
    fft(N, Y, X);
    forall i in 0..N-1 {
      if abs(Y(i) - (1+1.0i)) > 1.0e-5 then 
        writeln("Error: result incorrect.");
    }    
    
    //  benchmark computation
    startTime = getCurrentTime(TimeUnits.microseconds);
    for i in 1..NUMRUNS {
      fft(N, Y, X);
    }
    execTime = (getCurrentTime(TimeUnits.microseconds) - startTime)/NUMRUNS;
    if (printTimings) then
      writeln("fft_", N, ": ", execTime, "us = ", ops / execTime, " Mflop/s");
    else
      writeln("fft_", N);
  }
}
