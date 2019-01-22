package A:

	$first = ;

package B:
	$first = "package B";
	
package main
	print("$A::first\n");
	print("$B::first\n");
	