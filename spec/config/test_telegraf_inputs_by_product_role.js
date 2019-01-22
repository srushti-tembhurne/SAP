const fs = require('fs');

var assert  = require('assert');
var expect  = require('chai').expect;
var should  = require('chai').should();
var flatten = require('flat');

var telegrafInputs;
describe('telegraf inputs json', function() {
  // parse telegraf_inputs_by_product_role.json and flatten it down to 'input_type'
  telegrafInputs = flatten(
                     JSON.parse(
                      fs.readFileSync('./base/config/telegraf_inputs_by_product_role.json')), { maxDepth: 3 });

  describe('product role', function() {

    describe('exec input type' , function() {
      // mapreduce to array of exec input types
      let execTypes = Object.values(telegrafInputs)
            .map(x => x.filter(x => x.input_type === 'exec'))
            .reduce((acc, arr) => [...acc, ...arr], []);

      describe('parameters', function() {
        // reduce to get list of the parameters arrays
        let paramsArray = execTypes
              .reduce((acc, execType) => [...acc, ...[execType.parameters]], []);
              
        // pending test for timeout =< interval
        it('should have timeout =< interval');

        describe('command', function() {
          // reduce to array of 'command' parameter values
          let commands = paramsArray
                .map(params => params.filter(x =>  RegExp('^commands*').test(x))) // extract only commands param
                .reduce((acc, cmd) => [...acc, cmd[0]], []) // flatten all commands into one array
                .map(cmdparam => cmdparam.replace(/^commands\s+\=\s\[\"/, "")) // trim the 'commands = ["
                .map(cmdparam => cmdparam.replace(/\s*\"\]\s*$/, "")); // trim "] and end
                // we now have array of all the commands values

          // we need to create collection of all unique stratus scripts found in
          // commands and see if they have actual script in stratus repo
          let stratusScripts = new Set(commands
               .reduce((acc, cmdln) => [...acc, ...cmdln.split(' ')], []) // split all command params into single array
               .filter(x => RegExp('\/stratus').test(x))); // filter for stratus scripts
          stratusScripts.forEach( function(stratusScript) {
            it('stratus scripts exist', function() {
              let script = stratusScript.replace(/^.*\/stratus/, ".");
                 expect(function(){fs.statSync(script)}).to.not.throw('', '', `script ${script} does not exist`);
            });
          }); // for each script test
        }); // command
      }); // parameters
    }); // input exec type
  }); // product role
});
