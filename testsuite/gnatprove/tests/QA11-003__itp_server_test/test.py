from test_support import *
import time
import json

DEAD = "Dead"
INITIALIZED = "Initialized"
NEXT_UNPROVEN = "Next_Unproven_Node_Id"
NOTIFICATION = "notification"
NODE_CHANGE = "Node_change"
NODE_ID = "node_ID"
PARENT_ID = "parent_ID"
LTASK = "task"
UTASK = "Task"
UMESSAGE = "Message"
LMESSAGE = "message"
NEW_NODE = "New_node"
LMESSAGE = "message"
MESS_NOTIF = "mess_notif"
TASK_MONITOR = "Task_Monitor"


""" This tests is a commandline test for the itp server. It launches a server as
a background process, and then pass it request in JSON. The output to be checked
are notifications written in JSON"""

# This launches the itp_server
def launch_server(limit_line, input_file):

    installdir = spark_install_path()
    bindir = os.path.join(installdir, 'libexec', 'spark', 'bin')
    Env().add_path(bindir)

    cmd = ["gnat_server", "--limit-line", limit_line, "test.mlw"]
    # Create a pipe to give request to the process one by one.
    read, write = os.pipe()
    # process writes output to file, so we can avoid deadlocking
    with open ("proc.out", "w") as outfile:
        process = Run (cmd, cwd="gnatprove", input=read, output=outfile, bg=True, timeout=400)
        with open (input_file, "r") as in_file:
            for l in in_file:
                print(l)
                os.write(write, l)
                sleep(1)
        # Give the gnat_server time to end by itself. Thats why we send the
        # exit request
        process.wait()
    # read in the process output via the tempfile
    with open ("proc.out", "r") as infile:
        s = infile.read()
    s = re.sub('"pr_time" : ([0-9]*[.])?[0-9]+', '"pr_time" : "Not displayed"', s)
    # Parse the json outputs:
    l = s.split (">>>>")
    nb_unparsed = 0
    task_monitor = 0
    next_unproven = 0
    for i in l:
        try:
            pos = i.find("{")
            j = json.loads(i[pos:])
            notif_type = j[NOTIFICATION]
            if notif_type == NODE_CHANGE:
                print (NODE_CHANGE + " " + str(j[NODE_ID]))
            elif notif_type == NEW_NODE:
                print (NEW_NODE + " " + str(j[NODE_ID]) + " " + str(j[PARENT_ID]))
            elif notif_type == NEXT_UNPROVEN:
                # TODO this is ok but we print nothing
                next_unproven = next_unproven + 1
            elif notif_type == INITIALIZED:
                print (INITIALIZED)
            elif notif_type == DEAD:
                print (DEAD)
            elif notif_type == UTASK:
                print (notif_type)
                print (j[LTASK])
            elif notif_type == UMESSAGE:
                message = j[LMESSAGE]
                message_type = message[MESS_NOTIF]
                if message_type == TASK_MONITOR:
                    task_monitor = task_monitor + 1
                    # TODO ignore task_monitoring
                else:
                    print (UMESSAGE)
            else:
                print "TODO PROBLEM TO REPORT"
        except:
            if i != "\n" and i != " ":
                nb_unparsed = nb_unparsed + 1
                print ("UNPARSED NOTIFICATION " + i)
    if nb_unparsed > 1:
        print "PROBLEM WITH UNPARSED JSON NOTIFICATIONS"
    if next_unproven != 1:
        print "PROBLEM WITH NEXT_UNPROVEN_NODE"
    return "DONE"

prove_all(counterexample=False, prover=["cvc4"])
sleep(5)
result = launch_server(limit_line="test.adb:11:16:VC_POSTCONDITION", input_file="test.in")
print(result)