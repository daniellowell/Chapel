config var n : integer = 8;

var D : domain(2) = (1..n, 1..n);
var A : [D] integer;
var B : [D] integer;

[i,j in D] A(i,j) = (i - 1) * n + j;

writeln(A);

B = A;
A(1,1) = 500;

writeln(B);
